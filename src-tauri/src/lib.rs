//! NeuralLoop Books desktop backend.
//!
//! - `pipeline`: runs the book pipeline with the user's Python and streams progress
//! - `server`: serves each book's study site over the private `nlbook://` scheme
//! - `library`: the shelf of books and their saved progress
//! - `nudge`: Pip's gentle reminders (policy in a pure, tested function)
//! - `tray`: Pip in the menu bar

mod library;
mod nudge;
mod pipeline;
mod server;
mod settings;
mod storage;
mod tray;

use std::time::Duration;
use tauri::WindowEvent;

const FIRST_NUDGE_CHECK: Duration = Duration::from_secs(90);
const NUDGE_CHECK_EVERY: Duration = Duration::from_secs(600);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .manage(pipeline::Jobs::default())
        .register_uri_scheme_protocol("nlbook", |ctx, request| server::serve(ctx.app_handle(), &request))
        .invoke_handler(tauri::generate_handler![
            settings::get_settings,
            settings::set_settings,
            settings::check_setup,
            pipeline::start_pipeline,
            pipeline::cancel_pipeline,
            library::list_books,
            library::delete_book,
            library::save_progress,
            nudge::nudge_engaged,
            nudge::pause_nudges_today,
        ])
        .on_window_event(|window, event| {
            // Closing the window keeps Pip in the tray so nudges keep working.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .setup(|app| {
            tray::create(app)?;
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                std::thread::sleep(FIRST_NUDGE_CHECK);
                loop {
                    nudge::tick(&handle);
                    std::thread::sleep(NUDGE_CHECK_EVERY);
                }
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building NeuralLoop Books");
    app.run(|_handle, _event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Reopen { .. } = _event {
            tray::show_main_window(_handle);
        }
    });
}
