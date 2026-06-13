use tauri::{AppHandle, State};

use crate::{
    db,
    rules::model::{Rule, WatchedFolder},
    state::AppState,
    tray,
    watcher::WatcherCmd,
};

// ---------- Folders ----------

#[tauri::command]
pub fn get_watched_folders(state: State<AppState>) -> Result<Vec<WatchedFolder>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::list_folders(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn add_watched_folder(
    path: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<WatchedFolder, String> {
    let folder = WatchedFolder::new(path.clone());
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_folder(&conn, &folder).map_err(|e| e.to_string())?;
    }
    if let Ok(watcher) = state.watcher.lock() {
        if let Some(w) = watcher.as_ref() {
            let _ = w.tx.send(WatcherCmd::Add(path.into()));
        }
    }
    tray::rebuild(&app);
    Ok(folder)
}

#[tauri::command]
pub fn remove_watched_folder(
    id: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let path: Option<String> = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        conn.query_row(
            "SELECT path FROM watched_folders WHERE id=?1",
            rusqlite::params![id],
            |r| r.get(0),
        )
        .ok()
    };

    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::delete_folder(&conn, &id).map_err(|e| e.to_string())?;
    }

    if let Some(p) = path {
        if let Ok(watcher) = state.watcher.lock() {
            if let Some(w) = watcher.as_ref() {
                let _ = w.tx.send(WatcherCmd::Remove(p.into()));
            }
        }
    }

    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn toggle_watched_folder(
    id: String,
    enabled: bool,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::toggle_folder(&conn, &id, enabled).map_err(|e| e.to_string())?;
    drop(conn);
    tray::rebuild(&app);
    Ok(())
}

// ---------- Rules ----------

#[tauri::command]
pub fn get_rules(folder_id: String, state: State<AppState>) -> Result<Vec<Rule>, String> {
    let conn = state.db.lock().map_err(|e| e.to_string())?;
    db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn create_rule(
    folder_id: String,
    name: String,
    state: State<AppState>,
    app: AppHandle,
) -> Result<Rule, String> {
    let rule = Rule::new(folder_id, name);
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::insert_rule(&conn, &rule).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(rule)
}

#[tauri::command]
pub fn update_rule(rule: Rule, state: State<AppState>, app: AppHandle) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::update_rule(&conn, &rule).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn delete_rule(rule_id: String, state: State<AppState>, app: AppHandle) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::delete_rule(&conn, &rule_id).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(())
}

#[tauri::command]
pub fn toggle_rule(
    rule_id: String,
    enabled: bool,
    state: State<AppState>,
    app: AppHandle,
) -> Result<(), String> {
    {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        db::toggle_rule(&conn, &rule_id, enabled).map_err(|e| e.to_string())?;
    }
    tray::rebuild(&app);
    Ok(())
}

/// Manually triggers rule evaluation for all files in the folder.
#[tauri::command]
pub fn run_rules_now(folder_id: String, state: State<AppState>) -> Result<Vec<String>, String> {
    let (folder_path, rules) = {
        let conn = state.db.lock().map_err(|e| e.to_string())?;
        let path: String = conn
            .query_row(
                "SELECT path FROM watched_folders WHERE id=?1",
                rusqlite::params![folder_id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let rules = db::list_rules(&conn, &folder_id).map_err(|e| e.to_string())?;
        (path, rules)
    };

    let mut all_matched = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&folder_path) {
        for entry in entries.flatten() {
            let path = entry.path();
            let matched = crate::rules::engine::evaluate_file(&path, &rules);
            all_matched.extend(matched);
        }
    }

    Ok(all_matched)
}

/// Returns the macOS Finder tags available on this machine.
/// Always includes the 7 system colour tags; appends any custom user tags.
#[tauri::command]
pub fn get_macos_tags() -> Vec<String> {
    let system = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"];
    let mut tags: Vec<String> = system.iter().map(|s| s.to_string()).collect();

    // Try to read extra user-defined tags from Finder preferences
    if let Ok(out) = std::process::Command::new("defaults")
        .args(["read", "com.apple.finder", "FavoriteTagNames"])
        .output()
    {
        if let Ok(text) = String::from_utf8(out.stdout) {
            for line in text.lines() {
                let name = line.trim().trim_end_matches(',').trim_matches('"');
                if !name.is_empty() && name != "(" && name != ")" {
                    let s = name.to_string();
                    if !tags.contains(&s) {
                        tags.push(s);
                    }
                }
            }
        }
    }

    tags
}
