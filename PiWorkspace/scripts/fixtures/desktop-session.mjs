export function requireDedicatedDesktop() {
  if (process.env.PI_WORKSPACE_TEST_DESKTOP !== "dedicated") {
    throw new Error("This test controls macOS windows or input. Run it in a separate test desktop with PI_WORKSPACE_TEST_DESKTOP=dedicated.");
  }
}
