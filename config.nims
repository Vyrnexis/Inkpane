# Link SDL3 at build time instead of dlopen("libSDL3.so"). The official wrapper loads the
# unversioned name, which Debian/Ubuntu/Fedora only ship in their -dev packages; linking
# records the real soname (libSDL3.so.0), so end users just need the runtime package.
# inkpane-mcp only speaks D-Bus and needs no SDL at all.
if projectName() != "inkpane_mcp":
  switch("dynlibOverride", "SDL3")
  switch("passL", "-lSDL3")
