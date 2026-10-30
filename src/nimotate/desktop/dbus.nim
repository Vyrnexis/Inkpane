import glib

# One private session-bus connection shared by the portal client, the tray icon and the
# Nimotate control service. Exported objects dispatch into Nim closures.

const AppId* = "org.vyrnexis.Nimotate"   # reverse-DNS; matches the .desktop file name

type
  DBusError* = object of IOError

  MethodHandler* = proc(methodName: string, parameters: GVariant, invocation: pointer)
  PropertyHandler* = proc(propertyName: string): GVariant

  ExportedObject = ref object
    onMethod: MethodHandler
    onProperty: PropertyHandler

var
  connection: GDBusConnection
  appIdRegistered: bool
  exported: seq[ExportedObject]   # keeps handlers alive; GLib only holds raw pointers

############################
# Connection
############################

proc callRaw(destination, objectPath, interfaceName, methodName: string,
    parameters: GVariant, timeoutMs = 30_000): GVariant

proc registerAppId*() =
  ## Host apps have no sandbox app id; registering one lets portals attribute shortcuts
  ## and grants to our .desktop file. Must precede any other portal call on the connection.
  if appIdRegistered:
    return
  appIdRegistered = true
  try:
    let options = g_variant_builder_new(variantType("a{sv}"))
    let reply = callRaw("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
      "org.freedesktop.host.portal.Registry", "Register",
      g_variant_new("(s@a{sv})", AppId.cstring, g_variant_builder_end(options)))
    g_variant_builder_unref(options)
    g_variant_unref(reply)
  except DBusError:
    stderr.writeLine("nimotate: could not register app id: " & getCurrentExceptionMsg())

proc bus*(): GDBusConnection =
  if connection != nil:
    return connection

  var error: ptr GError
  let address = g_dbus_address_get_for_bus_sync(GBusTypeSession, nil, addr error)
  if address.isNil:
    raise newException(DBusError, takeErrorMessage(error, "D-Bus session bus not found"))
  connection = g_dbus_connection_new_for_address_sync(
    address,
    GDBusConnectionFlagsAuthenticationClient or GDBusConnectionFlagsMessageBusConnection,
    nil, nil, addr error
  )
  g_free(address)
  if connection.isNil:
    raise newException(DBusError, takeErrorMessage(error, "Could not connect to D-Bus"))
  connection

proc uniqueName*(): string =
  $g_dbus_connection_get_unique_name(bus())

proc pump*() =
  ## Dispatch pending D-Bus traffic without blocking (called from the SDL loop).
  while g_main_context_iteration(nil, 0) != 0:
    discard

proc wait*() =
  ## Sleep until a GLib source (D-Bus, a watched fd, a signal) has work, then dispatch it.
  discard g_main_context_iteration(nil, 1)

############################
# Calls and Signals
############################

proc callRaw(destination, objectPath, interfaceName, methodName: string,
    parameters: GVariant, timeoutMs = 30_000): GVariant =
  var error: ptr GError
  result = g_dbus_connection_call_sync(
    bus(), destination.cstring, objectPath.cstring, interfaceName.cstring,
    methodName.cstring, parameters, nil, GDBusCallFlagsNone, cint(timeoutMs), nil, addr error
  )
  if result.isNil:
    raise newException(DBusError, takeErrorMessage(error, methodName & " failed"))

proc call*(destination, objectPath, interfaceName, methodName: string,
    parameters: GVariant = nil, timeoutMs = 30_000): GVariant =
  ## Synchronous method call; the caller must g_variant_unref the reply.
  callRaw(destination, objectPath, interfaceName, methodName, parameters, timeoutMs)

proc emitSignal*(objectPath, interfaceName, signalName: string, parameters: GVariant = nil) =
  var error: ptr GError
  if g_dbus_connection_emit_signal(bus(), nil, objectPath.cstring, interfaceName.cstring,
      signalName.cstring, parameters, addr error) == 0:
    discard takeErrorMessage(error, "")

proc subscribe*(sender, interfaceName, member, objectPath, arg0: string,
    callback: GDBusSignalCallback) =
  proc orNil(value: string): cstring = (if value.len == 0: nil else: value.cstring)
  discard g_dbus_connection_signal_subscribe(bus(), sender.orNil, interfaceName.orNil,
    member.orNil, objectPath.orNil, arg0.orNil, GDBusSignalFlagsNone, callback, nil, nil)

############################
# Bus Names
############################

proc requestName*(name: string): bool =
  ## True when we became the primary owner; false if another instance already has it.
  const DoNotQueue = 4'u32
  const PrimaryOwner = 1'u32
  let reply = call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "RequestName", g_variant_new("(su)", name.cstring, DoNotQueue))
  var code: uint32
  g_variant_get(reply, "(u)", addr code)
  g_variant_unref(reply)
  code == PrimaryOwner

############################
# Exported Objects
############################

proc onMethodCall(conn: GDBusConnection, sender, objectPath, interfaceName, methodName: cstring,
    parameters: GVariant, invocation: pointer, userData: pointer) {.cdecl.} =
  let handler = cast[ExportedObject](userData)
  try:
    handler.onMethod($methodName, parameters, invocation)
  except CatchableError:
    g_dbus_method_invocation_return_dbus_error(invocation,
      "org.freedesktop.DBus.Error.Failed", getCurrentExceptionMsg().cstring)

proc onGetProperty(conn: GDBusConnection, sender, objectPath, interfaceName, propertyName: cstring,
    error: ptr ptr GError, userData: pointer): GVariant {.cdecl.} =
  let handler = cast[ExportedObject](userData)
  if handler.onProperty == nil:
    return nil
  try:
    handler.onProperty($propertyName)
  except CatchableError:
    nil

var vtable = GDBusInterfaceVTable(methodCall: onMethodCall, getProperty: onGetProperty)

proc exportObject*(objectPath, introspectionXml, interfaceName: string,
    onMethod: MethodHandler, onProperty: PropertyHandler = nil) =
  var error: ptr GError
  let nodeInfo = g_dbus_node_info_new_for_xml(introspectionXml.cstring, addr error)
  if nodeInfo.isNil:
    raise newException(DBusError, takeErrorMessage(error, "Bad introspection XML"))
  let interfaceInfo = g_dbus_node_info_lookup_interface(nodeInfo, interfaceName.cstring)
  let handler = ExportedObject(onMethod: onMethod, onProperty: onProperty)
  exported.add(handler)
  if g_dbus_connection_register_object(bus(), objectPath.cstring, interfaceInfo, addr vtable,
      cast[pointer](handler), nil, addr error) == 0:
    raise newException(DBusError, takeErrorMessage(error, "Could not export " & objectPath))

proc reply*(invocation: pointer, value: GVariant = nil) =
  g_dbus_method_invocation_return_value(invocation, value)
