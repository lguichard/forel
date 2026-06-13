use std::path::Path;

use anyhow::Result;

use super::model::{Condition, ConditionKind, Operator};

/// Returns true if the file at `path` satisfies the condition.
pub fn evaluate(condition: &Condition, path: &Path) -> Result<bool> {
    let meta = std::fs::metadata(path)?;

    match &condition.kind {
        ConditionKind::Name => {
            let name = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("");
            Ok(match_string(&condition.operator, name, &condition.value))
        }

        ConditionKind::Extension => {
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            Ok(match_string(
                &condition.operator,
                &ext,
                &condition.value.to_lowercase(),
            ))
        }

        ConditionKind::Kind => {
            let kind_str = if meta.is_dir() { "folder" } else { "file" };
            Ok(match_string(&condition.operator, kind_str, &condition.value))
        }

        ConditionKind::SizeBytes => {
            let size = meta.len();
            let threshold: u64 = condition.value.parse().unwrap_or(0);
            Ok(match condition.operator {
                Operator::Is => size == threshold,
                Operator::IsNot => size != threshold,
                Operator::GreaterThan => size > threshold,
                Operator::LessThan => size < threshold,
                _ => false,
            })
        }

        ConditionKind::DateModified => {
            let modified = meta.modified()?.duration_since(std::time::UNIX_EPOCH)?.as_secs();
            let threshold: u64 = condition.value.parse().unwrap_or(0);
            Ok(match condition.operator {
                Operator::Is => modified == threshold,
                Operator::IsNot => modified != threshold,
                Operator::Before => modified < threshold,
                Operator::After => modified > threshold,
                _ => false,
            })
        }

        ConditionKind::DateCreated => {
            let created = meta.created()?.duration_since(std::time::UNIX_EPOCH)?.as_secs();
            let threshold: u64 = condition.value.parse().unwrap_or(0);
            Ok(match condition.operator {
                Operator::Is => created == threshold,
                Operator::IsNot => created != threshold,
                Operator::Before => created < threshold,
                Operator::After => created > threshold,
                _ => false,
            })
        }

        ConditionKind::Contents => {
            let text = std::fs::read_to_string(path).unwrap_or_default();
            Ok(match_string(&condition.operator, &text, &condition.value))
        }

        // macOS-only: tags require xattr parsing (stubbed for now)
        ConditionKind::Tags => Ok(false),
    }
}

fn match_string(operator: &Operator, haystack: &str, needle: &str) -> bool {
    match operator {
        Operator::Is => haystack == needle,
        Operator::IsNot => haystack != needle,
        Operator::Contains => haystack.contains(needle),
        Operator::DoesNotContain => !haystack.contains(needle),
        Operator::StartsWith => haystack.starts_with(needle),
        Operator::EndsWith => haystack.ends_with(needle),
        Operator::MatchesRegex => regex::Regex::new(needle)
            .map(|re| re.is_match(haystack))
            .unwrap_or(false),
        _ => false,
    }
}
