use std::sync::atomic::Ordering;

use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};

use crate::{db, state::AppState, watcher::WatcherCmd};

const TRAY_ID: &str = "forel_tray";

enum TrayItem {
    Plain(MenuItem<tauri::Wry>),
    Check(CheckMenuItem<tauri::Wry>),
    Sep(PredefinedMenuItem<tauri::Wry>),
}

impl TrayItem {
    fn as_menu_item(&self) -> &dyn tauri::menu::IsMenuItem<tauri::Wry> {
        match self {
            TrayItem::Plain(i) => i,
            TrayItem::Check(i) => i,
            TrayItem::Sep(i) => i,
        }
    }
}

/// Returns a copy of `base` with a filled colored circle drawn in the
/// bottom-right quadrant — green when active, red when paused.
fn icon_with_dot(base: &tauri::image::Image<'_>, active: bool) -> tauri::image::Image<'static> {
    let w = base.width();
    let h = base.height();
    let mut rgba = base.rgba().to_vec();

    let dot_r = (w / 10).max(3) as i32;
    let cx = (5 * w / 6) as i32;
    let cy = (5 * h / 6) as i32;

    // White border ring for contrast against any background
    let border_r = dot_r + (dot_r / 4).max(1);
    for py in 0..h as i32 {
        for px in 0..w as i32 {
            let d2 = (px - cx).pow(2) + (py - cy).pow(2);
            if d2 <= border_r.pow(2) {
                let idx = ((py as u32 * w + px as u32) * 4) as usize;
                rgba[idx] = 255;
                rgba[idx + 1] = 255;
                rgba[idx + 2] = 255;
                rgba[idx + 3] = 255;
            }
        }
    }

    // Colored fill — macOS system green (#34C759) / red (#FF3B30)
    let (dr, dg, db) = if active {
        (52u8, 199u8, 89u8)
    } else {
        (255u8, 59u8, 48u8)
    };
    for py in 0..h as i32 {
        for px in 0..w as i32 {
            let d2 = (px - cx).pow(2) + (py - cy).pow(2);
            if d2 <= dot_r.pow(2) {
                let idx = ((py as u32 * w + px as u32) * 4) as usize;
                rgba[idx] = dr;
                rgba[idx + 1] = dg;
                rgba[idx + 2] = db;
                rgba[idx + 3] = 255;
            }
        }
    }

    tauri::image::Image::new_owned(rgba, w, h)
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    let icon = app
        .default_window_icon()
        .map(|b| icon_with_dot(b, true))
        .unwrap();

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .menu(&menu)
        .tooltip("Forel")
        .show_menu_on_left_click(true)
        .on_menu_event(handle_menu_event)
        .build(app)?;
    Ok(())
}

pub fn rebuild(app: &AppHandle) {
    let state = app.state::<AppState>();
    let active = !state.paused.load(Ordering::Relaxed);

    if let Ok(menu) = build_menu(app) {
        if let Some(tray) = app.tray_by_id(TRAY_ID) {
            let _ = tray.set_menu(Some(menu));
            if let Some(base) = app.default_window_icon() {
                let _ = tray.set_icon(Some(icon_with_dot(base, active)));
            }
        }
    }
}

fn handle_menu_event(app: &AppHandle, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref().to_string();
    match id.as_str() {
        "open" => {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
                let _ = w.set_focus();
            }
        }
        "quit" => app.exit(0),
        "toggle_watch" => {
            let state = app.state::<AppState>();
            let was_paused = state.paused.load(Ordering::Relaxed);
            let now_paused = !was_paused;
            state.paused.store(now_paused, Ordering::Relaxed);

            // Collect paths under db lock, then send commands without holding it
            let paths: Vec<String> = {
                let conn = state.db.lock().unwrap();
                let folders = db::list_folders(&conn).unwrap_or_default();
                if now_paused {
                    folders.into_iter().map(|f| f.path).collect()
                } else {
                    folders.into_iter().filter(|f| f.enabled).map(|f| f.path).collect()
                }
            };

            {
                let watcher = state.watcher.lock().unwrap();
                if let Some(w) = watcher.as_ref() {
                    for path in paths {
                        let cmd = if now_paused {
                            WatcherCmd::Remove(path.into())
                        } else {
                            WatcherCmd::Add(path.into())
                        };
                        let _ = w.tx.send(cmd);
                    }
                }
            }

            rebuild(app);
        }
        rule_id => {
            // Toggle individual rule
            let state = app.state::<AppState>();
            let toggled = {
                let conn = state.db.lock().unwrap();
                let current: Option<bool> = conn
                    .query_row(
                        "SELECT enabled FROM rules WHERE id=?1",
                        rusqlite::params![rule_id],
                        |r| r.get(0),
                    )
                    .ok();
                if let Some(enabled) = current {
                    let _ = db::toggle_rule(&conn, rule_id, !enabled);
                    true
                } else {
                    false
                }
            };
            if toggled {
                rebuild(app);
            }
        }
    }
}

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let state = app.state::<AppState>();
    let paused = state.paused.load(Ordering::Relaxed);

    let conn = state.db.lock().unwrap();
    let folders_with_rules = db::list_all_rules_with_folder(&conn).unwrap_or_default();

    let mut items: Vec<TrayItem> = Vec::new();

    // Primary action at top (mirrors Postgres.app pattern)
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "open", "Open Forel", true, None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));

    // Status row + toggle — descriptive text forces a decent menu width
    let (status_label, action_label) = if paused {
        ("🔴  File watching is paused", "Start Watching")
    } else {
        ("🟢  File watching is active", "Stop Watching")
    };

    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "status", status_label, false, None::<&str>,
    )?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "toggle_watch", action_label, true, None::<&str>,
    )?));
    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));

    // Rules grouped by folder
    let mut has_rules = false;
    for (folder, rules) in &folders_with_rules {
        if rules.is_empty() {
            continue;
        }
        let folder_name = std::path::Path::new(&folder.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&folder.path)
            .to_string();
        items.push(TrayItem::Plain(MenuItem::with_id(
            app,
            &format!("folder_{}", folder.id),
            folder_name,
            false,
            None::<&str>,
        )?));
        for rule in rules {
            has_rules = true;
            items.push(TrayItem::Check(CheckMenuItem::with_id(
                app,
                &rule.id,
                &rule.name,
                true,
                rule.enabled,
                None::<&str>,
            )?));
        }
    }

    if !has_rules {
        items.push(TrayItem::Plain(MenuItem::with_id(
            app, "no_rules", "No rules configured", false, None::<&str>,
        )?));
    }

    items.push(TrayItem::Sep(PredefinedMenuItem::separator(app)?));
    items.push(TrayItem::Plain(MenuItem::with_id(
        app, "quit", "Quit Forel", true, None::<&str>,
    )?));

    let refs: Vec<&dyn tauri::menu::IsMenuItem<tauri::Wry>> =
        items.iter().map(|i| i.as_menu_item()).collect();
    Menu::with_items(app, &refs)
}
