// Thin wrapper over the Tauri APIs, so the rest of the UI doesn't reach into globals.

const tauri = window.__TAURI__;

export const invoke = (command, args) => tauri.core.invoke(command, args);
export const listen = (event, handler) => tauri.event.listen(event, ({ payload }) => handler(payload));
export const pickFile = (filters) => tauri.dialog.open({ multiple: false, directory: false, filters });
export const notifications = tauri.notification;

/** Where the private nlbook:// scheme is reachable (Windows serves custom schemes over http). */
export const BOOKS_BASE =
  window.__NL_BASE__ || (navigator.userAgent.includes("Windows") ? "http://nlbook.localhost/" : "nlbook://localhost/");
