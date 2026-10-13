// Each run uses an isolated process: the Rust watchdog can stop an infinite
// JavaScript loop without abandoning a live thread or blocking the UI.
import Foundation
import JavaScriptCore

func emit(_ value: [String: Any]) {
    guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return }
    FileHandle.standardOutput.write(bytes)
    FileHandle.standardOutput.write(Data([10]))
}
guard let line = readLine(), let data = line.data(using: .utf8),
      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let source = request["source"] as? String,
      let context = JSContext() else { exit(1) }
var logs = [String]()
var exception: String?
context.exceptionHandler = { _, value in exception = value?.toString() ?? "JavaScript error" }
let log: @convention(block) (String) -> Void = { message in
    logs.append(String(message.prefix(2000)))
    if logs.count > 200 { logs.removeFirst(logs.count - 200) }
}
context.setObject(log, forKeyedSubscript: "__log" as NSString)
context.evaluateScript("var console = {log: function(){__log(Array.prototype.map.call(arguments,String).join(' '));}}; console.warn=console.error=console.log;")
let notify: @convention(block) (String, String) -> String = { op, payload in
    let value = payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? [:]
    emit(["type":"notify", "op":op,"payload":value])
    return readLine() ?? ""
}
context.setObject(notify, forKeyedSubscript: "__notify" as NSString)
context.evaluateScript("var notify={push:function(p){return __notify('push',JSON.stringify(p));},clear:function(group){return __notify('clear',JSON.stringify({group:group}));}};")
let fetch: @convention(block) (String, JSValue) -> [String: Any] = { rawURL, options in
    guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
        return ["status":0,"ok":false,"body":"Only http/https URLs are allowed"]
    }
    let opts = options.toDictionary() ?? [:]
    var req = URLRequest(url: url)
    req.httpMethod = opts["method"] as? String ?? "GET"
    req.timeoutInterval = 10
    if let body = opts["body"] as? String { req.httpBody = body.data(using: .utf8) }
    if let headers = opts["headers"] as? [String:String] { for (key,value) in headers {req.setValue(value,forHTTPHeaderField:key)} }
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var response: [String:Any] = ["status":0,"ok":false,"body":"timeout"]
    let task = URLSession.shared.dataTask(with:req) { data, result, error in
        let status = (result as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.map {String(decoding:$0.prefix(1_048_576),as:UTF8.self)} ?? error?.localizedDescription ?? ""
        lock.lock(); response = ["status":status,"ok":(200..<300).contains(status),"body":body]; lock.unlock()
        semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now()+10) == .timedOut {task.cancel()}
    lock.lock(); defer {lock.unlock()}; return response
}
context.setObject(fetch, forKeyedSubscript:"fetch" as NSString)
let function = context.evaluateScript("(function(input){\n" + source + "\n})")
let result = function?.call(withArguments:[request["input"] ?? [:]])
var outcome: [String:Any] = ["type":"result","ok":exception == nil,"logs":logs]
if let exception {outcome["error"] = exception}
if let result, !result.isUndefined, exception == nil {
    context.setObject(result,forKeyedSubscript:"__result" as NSString)
    if let encoded = context.evaluateScript("JSON.stringify(__result)")?.toString(), let bytes = encoded.data(using:.utf8), let value = try? JSONSerialization.jsonObject(with:bytes,options:[.fragmentsAllowed]) { outcome["result"]=value }
}
emit(outcome)
