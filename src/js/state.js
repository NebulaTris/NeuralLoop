// Shared state for the desktop screens.

export const app = {
  view: { name: "library" },
  books: [],
  setup: null,
  logs: {}, // recent pipeline output lines, by book id
};

let renderScreen = () => {};
export function setRenderer(render) {
  renderScreen = render;
}
export function go(name, params = {}) {
  app.view = { name, ...params };
  renderScreen();
}
