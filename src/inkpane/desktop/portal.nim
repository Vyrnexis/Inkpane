import std/[os, strutils, tables]

import dbus
import glib

# xdg-desktop-portal client: GlobalShortcuts and Screenshot here, RemoteDesktop (for
# inkpane-mcp) in remote.nim. Portal requests answer
# through Request::Response signals, which arrive while we pump the GLib main context.

const
  PortalBusName = "org.freedesktop.portal.Desktop"
  PortalObjectPath = "/org/freedesktop/portal/desktop"
  GlobalShortcutsInterface = "org.freedesktop.portal.GlobalShortcuts"
  ScreenshotInterface = "org.freedesktop.portal.Screenshot"
  RequestInterface = "org.freedesktop.portal.Request"
  SessionInterface = "org.freedesktop.portal.Session"
  InteractiveTimeoutSeconds = 300   # the user may be looking at a confirmation dialog
  ScreenshotTimeoutSeconds = 120    # the first time, the desktop asks the user to allow it

type
  PortalError* = object of IOError

  ShortcutBinding* = object
    id*: string
    description*: string
    trigger*: string

  ShortcutSession* = ref object
    sessionHandle: string
    triggers*: Table[string, string]   # shortcut id -> key the desktop assigned, as it words it

  PortalResponse = object
    code: uint32
    results: GVariant

var
  subscribed: bool
  pendingResponses: Table[string, PortalResponse]
  activatedShortcuts: seq[tuple[session, id: string]]
  tokenCounter: int

############################
# Signals
############################

proc onRequestResponse(connection: GDBusConnection,
    senderName, objectPath, interfaceName, signalName: cstring,
    parameters: GVariant, userData: pointer) {.cdecl.} =
  var code: uint32
  var results: GVariant
  g_variant_get(parameters, "(u@a{sv})", addr code, addr results)
  pendingResponses[$objectPath] = PortalResponse(code: code, results: results)

proc onShortcutActivated(connection: GDBusConnection,
    senderName, objectPath, interfaceName, signalName: cstring,
    parameters: GVariant, userData: pointer) {.cdecl.} =
  let sessionValue = g_variant_get_child_value(parameters, 0)
  let idValue = g_variant_get_child_value(parameters, 1)
  activatedShortcuts.add(($g_variant_get_string(sessionValue, nil), $g_variant_get_string(idValue, nil)))
  g_variant_unref(sessionValue)
  g_variant_unref(idValue)

proc onTimeout(timedOut: pointer): cint {.cdecl.} =
  cast[ptr bool](timedOut)[] = true
  0

proc ensureSubscribed() =
  if subscribed:
    return
  registerAppId()
  subscribe(PortalBusName, RequestInterface, "Response", "", "", onRequestResponse)
  subscribe(PortalBusName, GlobalShortcutsInterface, "Activated", PortalObjectPath, "", onShortcutActivated)
  subscribed = true

############################
# Requests
############################

proc newToken*(): string =
  inc tokenCounter
  "inkpane" & $getCurrentProcessId() & "_" & $tokenCounter

proc addString*(options: GVariantBuilder, key, value: string) =
  g_variant_builder_add(options, "{sv}", key.cstring, g_variant_new_string(value.cstring))

proc newOptions*(token: string): GVariantBuilder =
  result = newBuilder("a{sv}")
  if token.len > 0:
    result.addString("handle_token", token)

proc portalRequest*(interfaceName, methodName: string, timeoutSeconds: int,
    buildParameters: proc(token: string): GVariant): GVariant =
  # Returns the a{sv} results of a successful request; the caller must unref them.
  ensureSubscribed()
  let token = newToken()
  let sender = uniqueName().strip(chars = {':'}, trailing = false).replace(".", "_")
  let expectedPath = PortalObjectPath & "/request/" & sender & "/" & token
  let reply =
    try:
      call(PortalBusName, PortalObjectPath, interfaceName, methodName, buildParameters(token))
    except DBusError:
      raise newException(PortalError, getCurrentExceptionMsg())

  var handle: cstring
  g_variant_get(reply, "(&o)", addr handle)
  let handlePath = $handle
  g_variant_unref(reply)

  # Sleep in GLib until the Response signal (or the timeout) arrives.
  var timedOut = false
  let timeout = g_timeout_add_seconds(cuint(timeoutSeconds), onTimeout, addr timedOut)
  defer:
    if not timedOut: discard g_source_remove(timeout)
  while true:
    for path in [expectedPath, handlePath]:
      if path in pendingResponses:
        let response = pendingResponses[path]
        pendingResponses.del(path)
        case response.code
        of 0: return response.results
        of 1:
          g_variant_unref(response.results)
          raise newException(PortalError, "The request was cancelled.")
        else:
          g_variant_unref(response.results)
          raise newException(PortalError, methodName & " was rejected by the desktop portal.")
    if timedOut:
      try:   # take down any dialog the request left on screen
        g_variant_unref(call(PortalBusName, handlePath, RequestInterface, "Close"))
      except DBusError:
        discard
      raise newException(PortalError, "Timed out waiting for the desktop portal.")
    discard g_main_context_iteration(nil, 1)

############################
# GlobalShortcuts
############################

proc globalShortcutsAvailable*(): bool =
  ensureSubscribed()
  try:
    let reply = call(PortalBusName, PortalObjectPath, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", GlobalShortcutsInterface.cstring, "version".cstring))
    g_variant_unref(reply)
    true
  except DBusError:
    false

proc closeSession(handle: string) =
  try:
    g_variant_unref(call(PortalBusName, handle, SessionInterface, "Close"))
  except DBusError:
    discard

proc bindShortcuts*(bindings: openArray[ShortcutBinding]): ShortcutSession =
  ## The desktop owns the final key assignment; triggers are suggestions it may show
  ## in a confirmation dialog the first time.
  let createResults = portalRequest(GlobalShortcutsInterface, "CreateSession",
      InteractiveTimeoutSeconds, proc(token: string): GVariant =
    let options = newOptions(token)
    options.addString("session_handle_token", newToken())
    g_variant_new("(@a{sv})", options.finish()))
  let handleValue = g_variant_lookup_value(createResults, "session_handle", variantType("s"))
  g_variant_unref(createResults)
  if handleValue.isNil:
    raise newException(PortalError, "The desktop portal did not return a session.")
  let sessionHandle = $g_variant_get_string(handleValue, nil)
  g_variant_unref(handleValue)

  let shortcutList = @bindings
  result = ShortcutSession(sessionHandle: sessionHandle)
  try:
    let results = portalRequest(GlobalShortcutsInterface, "BindShortcuts",
        InteractiveTimeoutSeconds, proc(token: string): GVariant =
      let shortcuts = newBuilder("a(sa{sv})")
      for binding in shortcutList:
        let details = newOptions("")
        details.addString("description", binding.description)
        details.addString("preferred_trigger", binding.trigger)
        g_variant_builder_add(shortcuts, "(s@a{sv})", binding.id.cstring, details.finish())
      g_variant_new("(o@a(sa{sv})s@a{sv})", sessionHandle.cstring, shortcuts.finish(),
        "".cstring, newOptions(token).finish()))
    let assigned = g_variant_lookup_value(results, "shortcuts", variantType("a(sa{sv})"))
    if not assigned.isNil:
      for i in 0 ..< g_variant_n_children(assigned):
        let shortcut = g_variant_get_child_value(assigned, i)
        let idValue = g_variant_get_child_value(shortcut, 0)
        let details = g_variant_get_child_value(shortcut, 1)
        let trigger = g_variant_lookup_value(details, "trigger_description", variantType("s"))
        result.triggers[$g_variant_get_string(idValue, nil)] =
          if trigger.isNil: "" else: $g_variant_get_string(trigger, nil)
        if not trigger.isNil: g_variant_unref(trigger)
        g_variant_unref(details)
        g_variant_unref(idValue)
        g_variant_unref(shortcut)
      g_variant_unref(assigned)
    g_variant_unref(results)
  except CatchableError:
    closeSession(sessionHandle)
    raise

proc takeActivated*(session: ShortcutSession): seq[string] =
  if session.isNil:
    return
  for activation in activatedShortcuts:
    if activation.session == session.sessionHandle:
      result.add(activation.id)
  activatedShortcuts.setLen(0)

############################
# Screenshot
############################

proc takeScreenshot*(): string =
  ## Screenshot of the whole desktop, without a dialog; returns the PNG's path. The
  ## portal writes the file and the caller owns it from then on.
  let results = portalRequest(ScreenshotInterface, "Screenshot", ScreenshotTimeoutSeconds,
    proc(token: string): GVariant =
      let options = newOptions(token)
      g_variant_builder_add(options, "{sv}", "interactive".cstring, g_variant_new_boolean(0))
      g_variant_new("(s@a{sv})", "".cstring, options.finish()))
  let uriValue = g_variant_lookup_value(results, "uri", variantType("s"))
  g_variant_unref(results)
  if uriValue.isNil:
    raise newException(PortalError, "The desktop portal returned no screenshot.")
  let address = $g_variant_get_string(uriValue, nil)
  g_variant_unref(uriValue)
  if not address.startsWith("file://"):
    raise newException(PortalError, "The screenshot is not a local file: " & address)
  var i = "file://".len   # the path, with %XX escapes decoded
  while i < address.len:
    if address[i] == '%' and i + 2 < address.len:
      result.add(chr(fromHex[int](address[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(address[i])
      inc i
