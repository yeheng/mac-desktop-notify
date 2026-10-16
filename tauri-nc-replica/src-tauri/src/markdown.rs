//! Markdown 切分与纯文本摘要：Swift `MarkdownRenderer.swift` +
//! `Toast/MarkdownPreview.swift` 的移植。
//!
//! 「围栏在哪」只有这一份定义：摘要（收起态卡片）与展开态渲染共用同一套
//! 切分，CRLF 也在这里归一——从 Windows 味工具推来的正文对每个消费者
//! 表现一致。

/// 一段同类连续行。
#[derive(Clone, Debug, PartialEq)]
pub enum Segment {
    Prose(Vec<String>),
    Heading { text: String, level: usize },
    List { items: Vec<String>, ordered: bool },
    Code(Vec<String>),
}

/// ATX 标题标记：1–6 个 '#' 后跟空白。
fn match_heading(line: &str) -> Option<(String, usize)> {
    let trimmed = line.trim_start_matches('#');
    let level = line.len() - trimmed.len();
    if level == 0 || level > 6 {
        return None;
    }
    if !trimmed.starts_with(char::is_whitespace) {
        return None;
    }
    Some((trimmed.trim_start().to_owned(), level))
}

/// 列表标记：'-'/'*'/'+' 或数字后跟 '.'/')'，再跟空白。
fn match_list_marker(line: &str) -> Option<(bool, String)> {
    for prefix in ["- ", "* ", "+ "] {
        if let Some(rest) = line.strip_prefix(prefix) {
            return Some((false, rest.to_owned()));
        }
    }
    let digits: String = line.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    let rest = &line[digits.len()..];
    for separator in [". ", ") "] {
        if let Some(text) = rest.strip_prefix(separator) {
            return Some((true, text.to_owned()));
        }
    }
    None
}

/// Swift `MarkdownRenderer.segments(in:)`。
pub fn segments(body: &str) -> Vec<Segment> {
    let normalized = body.replace("\r\n", "\n");
    let mut out: Vec<Segment> = Vec::new();
    let mut prose: Vec<String> = Vec::new();
    let mut list_items: Vec<String> = Vec::new();
    let mut list_ordered = false;
    let mut list_pending = false;
    let mut code: Vec<String> = Vec::new();
    let mut in_code = false;

    macro_rules! flush_prose {
        () => {
            if !prose.is_empty() {
                out.push(Segment::Prose(std::mem::take(&mut prose)));
            }
        };
    }
    macro_rules! flush_list {
        () => {
            if list_pending {
                out.push(Segment::List {
                    items: std::mem::take(&mut list_items),
                    ordered: list_ordered,
                });
                list_pending = false;
            }
        };
    }

    for line in normalized.split('\n') {
        if line.starts_with("```") {
            if in_code {
                // 空围栏（紧邻闭合）也仍然是一个代码块。
                out.push(Segment::Code(std::mem::take(&mut code)));
            } else {
                flush_prose!();
                flush_list!();
            }
            in_code = !in_code;
        } else if in_code {
            code.push(line.to_owned());
        } else if line.trim().is_empty() {
            // 空行是段落边界：prose 与 list 都不会跨越它合并。
            flush_prose!();
            flush_list!();
        } else if let Some((text, level)) = match_heading(line) {
            flush_prose!();
            flush_list!();
            out.push(Segment::Heading { text, level });
        } else if let Some((ordered, text)) = match_list_marker(line) {
            if list_pending && list_ordered != ordered {
                // 列表段内标记翻转：关闭旧列表另起一个，不发明混合标记。
                flush_list!();
            }
            if !list_pending {
                flush_prose!();
                list_pending = true;
                list_ordered = ordered;
                list_items = Vec::new();
            }
            list_items.push(text);
        } else {
            if list_pending {
                // 列表项后紧跟非列表文本且无空行：列表结束，另起段落。
                flush_list!();
            }
            prose.push(line.to_owned());
        }
    }
    if in_code {
        out.push(Segment::Code(code));
    } else {
        flush_prose!();
        flush_list!();
    }
    out
}

/// Swift `MarkdownPreview.text(_:maxLines:)`：Markdown → 纯文本摘要。
/// 代码块整体丢弃，语法标记永不泄漏，最多 maxLines 行以空格连接。
pub fn preview_text(body: &str, max_lines: usize) -> String {
    if max_lines == 0 || body.is_empty() {
        return String::new();
    }
    let lines: Vec<String> = segments(body)
        .iter()
        .flat_map(|segment| match segment {
            Segment::Prose(lines) => lines.clone(),
            Segment::Heading { text, .. } => vec![text.clone()],
            Segment::List { items, .. } => items.clone(),
            Segment::Code(_) => Vec::new(),
        })
        .map(|line| line.trim().to_owned())
        .filter(|line| !line.is_empty())
        .take(max_lines)
        .collect();
    lines.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segmentation_matches_swift() {
        let segs = segments("# 标题\n\n一段 **粗体**\n\n- 甲\n- 乙\n\n1. 第一\n2. 第二\n\n```\ncode\n```\n尾");
        assert_eq!(
            segs,
            vec![
                Segment::Heading {
                    text: "标题".into(),
                    level: 1
                },
                Segment::Prose(vec!["一段 **粗体**".into()]),
                Segment::List {
                    items: vec!["甲".into(), "乙".into()],
                    ordered: false
                },
                Segment::List {
                    items: vec!["第一".into(), "第二".into()],
                    ordered: true
                },
                Segment::Code(vec!["code".into()]),
                Segment::Prose(vec!["尾".into()]),
            ]
        );
    }

    #[test]
    fn crlf_and_blank_line_rules() {
        // CRLF 归一：段落与围栏行为与 LF 一致。
        let segs = segments("a\r\nb\r\n\r\nc");
        assert_eq!(
            segs,
            vec![Segment::Prose(vec!["a".into(), "b".into()]), Segment::Prose(vec!["c".into()])]
        );
        // 列表后紧跟非列表文本且无空行：列表结束另起段落。
        let segs = segments("- a\ntail");
        assert_eq!(
            segs,
            vec![
                Segment::List {
                    items: vec!["a".into()],
                    ordered: false
                },
                Segment::Prose(vec!["tail".into()])
            ]
        );
        // 空围栈仍然是一个代码块。
        let segs = segments("```\n```");
        assert_eq!(segs, vec![Segment::Code(vec![])]);
        // 未闭合的围栏：EOF 时收口。
        let segs = segments("```\nx");
        assert_eq!(segs, vec![Segment::Code(vec!["x".into()])]);
        // 标记翻转：新旧列表分开。
        let segs = segments("- a\n1. b");
        assert_eq!(
            segs,
            vec![
                Segment::List {
                    items: vec!["a".into()],
                    ordered: false
                },
                Segment::List {
                    items: vec!["b".into()],
                    ordered: true
                },
            ]
        );
    }

    #[test]
    fn preview_drops_code_and_markers() {
        assert_eq!(preview_text("## 摘要\n\n- 甲\n- 乙", 2), "摘要 甲");
        assert_eq!(preview_text("```\nlog dump\n```", 2), "");
        assert_eq!(preview_text("", 2), "");
        assert_eq!(preview_text("a\n\nb\n\nc", 2), "a b");
    }
}
