//! Markdown → plain-text summary, ported from Swift `MarkdownPreview`.
//!
//! The collapsed toast and history rows show prose, never raw syntax: a body
//! pushed as `## 摘要\n\n- 甲` must read as "摘要 甲", not as Markdown source.
//! Code blocks are dropped entirely — log dumps read as noise two lines at a
//! time, and their ``` markers would leak into the summary as backticks.
//!
//! Pure logic: no GPUI types, so the segmentation and flattening are testable
//! without a window server.

/// One block segment of a Markdown body, mirroring the renderer's slots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Segment {
    /// Plain prose lines (no markers stripped — there are none).
    Prose(Vec<String>),
    /// `#`-prefixed line; level dropped, only the text survives.
    Heading(String),
    /// `- item` / `1. item` lines; markers dropped, items kept.
    List(Vec<String>),
    /// Fenced code block; produces no summary text at all.
    Code,
}

/// Splits a body into segments the same way the expanded renderer does, so a
/// summary is always a prefix of what the expanded body will actually say.
pub(crate) fn segments(body: &str) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    let mut in_code = false;
    for raw in body.lines() {
        let line = raw.trim_end();
        if line.trim_start().starts_with("```") {
            in_code = !in_code;
            out.push(Segment::Code);
            continue;
        }
        if in_code {
            // Fence opened but not yet closed: still code, still dropped.
            continue;
        }
        if let Some(heading) = heading_text(line) {
            out.push(Segment::Heading(heading.to_owned()));
            continue;
        }
        if let Some(item) = list_item_text(line) {
            match out.last_mut() {
                // Consecutive list lines accumulate into one list segment.
                Some(Segment::List(items)) => items.push(item.to_owned()),
                _ => out.push(Segment::List(vec![item.to_owned()])),
            }
            continue;
        }
        if line.trim().is_empty() {
            // Blank lines are paragraph breaks, not prose content.
            continue;
        }
        match out.last_mut() {
            Some(Segment::Prose(lines)) => lines.push(line.to_owned()),
            _ => out.push(Segment::Prose(vec![line.to_owned()])),
        }
    }
    out
}

/// `## 摘要` → `摘要`; only 1-6 `#` followed by a space are headings,
/// matching the renderer (so `#tag` stays prose).
fn heading_text(line: &str) -> Option<&str> {
    let hashes = line.len() - line.trim_start_matches('#').len();
    let rest = &line[hashes..];
    (1..=6).contains(&hashes)
        .then(|| rest.strip_prefix(' '))
        .flatten()
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

/// `- item` / `* item` / `1. item` → `item`.
fn list_item_text(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    let (marker, rest) = if let Some(rest) = trimmed.strip_prefix("- ") {
        ("-", rest)
    } else if let Some(rest) = trimmed.strip_prefix("* ") {
        ("*", rest)
    } else {
        let digits = trimmed.len() - trimmed.trim_start_matches(|c: char| c.is_ascii_digit()).len();
        if digits > 0 && trimmed[digits..].starts_with(". ") {
            ("1.", trimmed[digits + 2..].trim())
        } else {
            return None;
        }
    };
    let _ = marker;
    let item = rest.trim();
    (!item.is_empty()).then_some(item)
}

/// Flattens `body` to at most `max_lines` lines of plain text joined by a
/// space. Markdown markers never survive; code blocks contribute nothing.
pub(crate) fn preview_text(body: &str, max_lines: usize) -> String {
    if max_lines == 0 || body.is_empty() {
        return String::new();
    }
    let mut lines: Vec<String> = Vec::new();
    for segment in segments(body) {
        match segment {
            Segment::Prose(prose) => lines.extend(prose),
            Segment::Heading(text) => lines.push(text),
            Segment::List(items) => lines.extend(items),
            Segment::Code => {}
        }
    }
    let kept: Vec<&str> = lines
        .iter()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty())
        .take(max_lines)
        .collect();
    kept.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headings_and_lists_lose_their_markers() {
        assert_eq!(
            preview_text("## 部署摘要\n\n- API ✅\n- Web ✅", 5),
            "部署摘要 API ✅ Web ✅"
        );
        assert_eq!(preview_text("- 甲\n- 乙", 5), "甲 乙");
        assert_eq!(preview_text("1. 第一步\n2. 第二步", 5), "第一步 第二步");
        assert_eq!(preview_text("### 标题", 3), "标题");
    }

    #[test]
    fn code_blocks_are_dropped_not_leaked() {
        assert_eq!(preview_text("正文\n```\nlog line\n```\n结尾", 5), "正文 结尾");
        // Unterminated fence: the rest is still code.
        assert_eq!(preview_text("之前\n```\nnever shown", 5), "之前");
        assert_eq!(preview_text("```\nonly code\n```", 5), "");
    }

    #[test]
    fn max_lines_truncates_but_never_mid_marker() {
        let body = "**第一行**\n*第二行*\n`第三行`";
        assert_eq!(preview_text(body, 2), "**第一行** *第二行*");
        // Inline markers survive — only block syntax is stripped, like Swift.
        assert_eq!(preview_text(body, 0), "");
    }

    #[test]
    fn non_headings_stay_prose() {
        // `#tag` without a space is prose, not a heading.
        assert_eq!(preview_text("#tag 不是标题", 3), "#tag 不是标题");
        assert_eq!(preview_text("####### 七个井号", 3), "####### 七个井号");
        assert_eq!(preview_text("", 3), "");
        assert_eq!(preview_text("   \n  \n", 3), "");
    }

    #[test]
    fn consecutive_lists_merge_and_blank_lines_break_content() {
        let segments = segments("段落一\n\n段落二\n- a\n- b\n普通行");
        // Blank lines carry no content; prose accumulates, lists merge, and a
        // prose line after a list starts a new prose segment.
        assert_eq!(
            segments,
            vec![
                Segment::Prose(vec!["段落一".into(), "段落二".into()]),
                Segment::List(vec!["a".into(), "b".into()]),
                Segment::Prose(vec!["普通行".into()]),
            ]
        );
        // The preview reads the same either way.
        assert_eq!(preview_text("段落一\n\n段落二", 5), "段落一 段落二");
    }
}
