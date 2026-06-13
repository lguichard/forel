use std::path::Path;

use anyhow::{bail, Context, Result};

use super::model::{Action, ActionKind};

/// Executes the action on the file at `path`.
pub fn execute(action: &Action, path: &Path) -> Result<()> {
    match &action.kind {
        ActionKind::MoveToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .context("MoveToFolder requires 'destination' param")?;
            let file_name = path.file_name().context("no file name")?;
            let dest = Path::new(dest_dir).join(file_name);
            std::fs::rename(path, &dest)
                .with_context(|| format!("move {:?} → {:?}", path, dest))?;
        }

        ActionKind::CopyToFolder => {
            let dest_dir = action
                .params
                .get("destination")
                .and_then(|v| v.as_str())
                .context("CopyToFolder requires 'destination' param")?;
            let file_name = path.file_name().context("no file name")?;
            let dest = Path::new(dest_dir).join(file_name);
            std::fs::copy(path, &dest)
                .with_context(|| format!("copy {:?} → {:?}", path, dest))?;
        }

        ActionKind::Rename => {
            let pattern = action
                .params
                .get("pattern")
                .and_then(|v| v.as_str())
                .context("Rename requires 'pattern' param")?;
            let new_name = apply_rename_pattern(pattern, path)?;
            let dest = path.with_file_name(new_name);
            std::fs::rename(path, &dest)
                .with_context(|| format!("rename {:?} → {:?}", path, dest))?;
        }

        ActionKind::MoveToTrash => {
            // On macOS, move to ~/.Trash
            let file_name = path.file_name().context("no file name")?;
            let trash = dirs_next()?;
            let dest = trash.join(file_name);
            std::fs::rename(path, &dest)?;
        }

        ActionKind::Delete => {
            if path.is_dir() {
                std::fs::remove_dir_all(path)?;
            } else {
                std::fs::remove_file(path)?;
            }
        }

        ActionKind::AddTag => {
            let tag = action
                .params
                .get("tag")
                .and_then(|v| v.as_str())
                .context("AddTag requires 'tag' param")?;
            apply_file_tag(path, tag, true)?;
        }

        ActionKind::RemoveTag => {
            let tag = action
                .params
                .get("tag")
                .and_then(|v| v.as_str())
                .context("RemoveTag requires 'tag' param")?;
            apply_file_tag(path, tag, false)?;
        }

        ActionKind::RunScript => {
            let script = action
                .params
                .get("script")
                .and_then(|v| v.as_str())
                .context("RunScript requires 'script' param")?;
            std::process::Command::new("bash")
                .args(["-c", script])
                .env("FOREL_FILE", path)
                .spawn()?;
        }
    }

    Ok(())
}

/// Substitutes tokens in rename patterns.
/// Supported tokens: {name}, {extension}, {date_created}, {date_modified}
fn apply_rename_pattern(pattern: &str, path: &Path) -> Result<String> {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");

    let meta = std::fs::metadata(path)?;
    let modified: chrono::DateTime<chrono::Local> = meta.modified()?.into();
    let created: chrono::DateTime<chrono::Local> = meta.created()?.into();

    let result = pattern
        .replace("{name}", stem)
        .replace("{extension}", ext)
        .replace("{date_modified}", &modified.format("%Y-%m-%d").to_string())
        .replace("{date_created}", &created.format("%Y-%m-%d").to_string());

    if result.is_empty() {
        bail!("rename pattern produced empty filename");
    }

    if ext.is_empty() {
        Ok(result)
    } else {
        Ok(format!("{}.{}", result, ext))
    }
}

#[cfg(target_os = "macos")]
fn dirs_next() -> Result<std::path::PathBuf> {
    let home = std::env::var("HOME").context("HOME not set")?;
    Ok(std::path::PathBuf::from(home).join(".Trash"))
}

#[cfg(not(target_os = "macos"))]
fn dirs_next() -> Result<std::path::PathBuf> {
    bail!("trash is only implemented on macOS")
}

// ---------- macOS Finder tags via xattr ----------

const TAGS_XATTR: &str = "com.apple.metadata:_kMDItemUserTags";

/// Adds or removes a named Finder tag on `path`.
///
/// Tags are stored as a binary-plist–encoded `Vec<String>` in the extended
/// attribute `com.apple.metadata:_kMDItemUserTags`.  Finder reads them live
/// so the change is visible immediately without any Finder restart.
fn apply_file_tag(path: &Path, tag: &str, add: bool) -> Result<()> {
    // Read the current tag list (empty if the xattr is absent or unreadable).
    let mut tags: Vec<String> = xattr::get(path, TAGS_XATTR)
        .ok()
        .flatten()
        .and_then(|bytes| plist::from_bytes::<Vec<String>>(&bytes).ok())
        .unwrap_or_default();

    if add {
        if !tags.iter().any(|t| t == tag) {
            tags.push(tag.to_string());
        }
    } else {
        tags.retain(|t| t != tag);
    }

    // Serialise back to binary plist and write the xattr.
    let mut buf: Vec<u8> = Vec::new();
    plist::to_writer_binary(std::io::Cursor::new(&mut buf), &tags)
        .context("failed to serialise tags plist")?;
    xattr::set(path, TAGS_XATTR, &buf).context("failed to write tags xattr")?;

    Ok(())
}
