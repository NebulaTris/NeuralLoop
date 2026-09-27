//! Pip in the menu bar / system tray.

use crate::nudge::pause_until_tomorrow;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{App, AppHandle, Emitter, Manager};

pub fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

pub fn create(app: &App) -> tauri::Result<()> {
    let menu = Menu::with_items(
        app,
        &[
            &MenuItem::with_id(app, "open", "Open NeuralLoop Books", true, None::<&str>)?,
            &MenuItem::with_id(app, "add", "Add a book…", true, None::<&str>)?,
            &MenuItem::with_id(app, "pause", "Pause nudges until tomorrow", true, None::<&str>)?,
            &MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?,
        ],
    )?;
    let mut tray = TrayIconBuilder::with_id("pip")
        .tooltip("NeuralLoop Books · Pip")
        .menu(&menu)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "add" => {
                show_main_window(app);
                let _ = app.emit("menu-add-book", ());
            }
            "pause" => pause_until_tomorrow(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main_window(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}
