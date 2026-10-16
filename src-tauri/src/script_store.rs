//! 脚本文件存储（Swift `ScriptStore` 移植）：按名读取 scripts/ 目录下的
//! `<name>.js`。名字校验与推送入口共用同一条规则（`model::valid_script`），
//! 两处漂移等于路径穿越。源码由 bun 子进程引擎执行（`script_host.rs`），
//! 本模块只负责磁盘。

use std::path::PathBuf;

use crate::model::valid_script;

#[derive(Debug, PartialEq, Eq)]
pub enum ScriptStoreError {
    InvalidName,
    NotFound,
    ReadFailed(String),
}

pub struct ScriptStore {
    directory: PathBuf,
}

impl ScriptStore {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    /// 默认存储（scripts/ 目录；建不出来只降级到每次 load 报错，
    /// 不掩盖「目录坏了」和「脚本不存在」的区别——Swift 同款）。
    pub fn shared() -> Self {
        let directory = crate::config::scripts_dir();
        if let Err(e) = std::fs::create_dir_all(&directory) {
            eprintln!("[script] 脚本目录创建失败：{e}");
        }
        Self::new(directory)
    }

    /// 「没有这个脚本」和「文件在但读不了」是两种错误：readFailed 带着
    /// 真实原因，用户不用对着一个明明存在的文件排查。
    pub fn load(&self, name: &str) -> Result<String, ScriptStoreError> {
        if !valid_script(name) {
            return Err(ScriptStoreError::InvalidName);
        }
        let file = self.directory.join(format!("{name}.js"));
        if !file.is_file() {
            return Err(ScriptStoreError::NotFound);
        }
        std::fs::read_to_string(&file).map_err(|e| ScriptStoreError::ReadFailed(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> ScriptStore {
        let dir = std::env::temp_dir().join(format!("nc-scripts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        ScriptStore::new(dir)
    }

    #[test]
    fn load_reads_the_named_file() {
        let store = store();
        std::fs::write(store.directory.join("ci.js"), "return {ok: true}").unwrap();
        assert_eq!(store.load("ci").unwrap(), "return {ok: true}");
    }

    #[test]
    fn missing_and_unreadable_are_distinguished() {
        let store = store();
        assert_eq!(store.load("absent"), Err(ScriptStoreError::NotFound));

        let unreadable = store.directory.join("locked.js");
        std::fs::write(&unreadable, b"x").unwrap();
        let mut perm = std::fs::metadata(&unreadable).unwrap().permissions();
        use std::os::unix::fs::PermissionsExt;
        perm.set_mode(0o000);
        std::fs::set_permissions(&unreadable, perm).unwrap();
        match store.load("locked") {
            Err(ScriptStoreError::ReadFailed(_)) => {}
            other => panic!("expected readFailed, got {other:?}"),
        }
    }

    #[test]
    fn invalid_names_never_touch_the_filesystem() {
        let store = store();
        for name in ["", "../oops", "a/b", "带中文", "x y"] {
            assert_eq!(store.load(name), Err(ScriptStoreError::InvalidName), "{name}");
        }
        // 边界内合法：64 字符上限。
        let long_ok = "a".repeat(64);
        let too_long = "a".repeat(65);
        assert_eq!(store.load(&long_ok), Err(ScriptStoreError::NotFound));
        assert_eq!(store.load(&too_long), Err(ScriptStoreError::InvalidName));
    }
}
