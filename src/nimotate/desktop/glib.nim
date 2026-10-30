# Minimal GLib / GIO bindings for D-Bus: portal calls, the tray icon and our own service.
# GLib is not GTK; it is present on every Linux desktop (Qt/KDE use it too).

############################
# Libraries and Types
############################

const
  glibLib = "libglib-2.0.so.0"
  gobjectLib = "libgobject-2.0.so.0"
  gioLib = "libgio-2.0.so.0"

  GBusTypeSession* = cint(2)
  GDBusConnectionFlagsAuthenticationClient* = cint(1)
  GDBusConnectionFlagsMessageBusConnection* = cint(8)
  GDBusCallFlagsNone* = cint(0)
  GDBusSignalFlagsNone* = cint(0)

type
  GError* {.bycopy.} = object
    domain*: uint32
    code*: cint
    message*: cstring

  GVariant* = pointer
  GVariantBuilder* = pointer
  GDBusConnection* = pointer
  GUnixFDList* = pointer

  GDBusMethodCallback* = proc(
    connection: GDBusConnection,
    sender, objectPath, interfaceName, methodName: cstring,
    parameters: GVariant,
    invocation: pointer,
    userData: pointer
  ) {.cdecl.}

  GDBusGetPropertyCallback* = proc(
    connection: GDBusConnection,
    sender, objectPath, interfaceName, propertyName: cstring,
    error: ptr ptr GError,
    userData: pointer
  ): GVariant {.cdecl.}

  GDBusInterfaceVTable* {.bycopy.} = object
    methodCall*: GDBusMethodCallback
    getProperty*: GDBusGetPropertyCallback
    setProperty*: pointer
    padding: array[8, pointer]

  GSourceFunc* = proc(userData: pointer): cint {.cdecl.}   # return 0 to remove the source

  GDBusSignalCallback* = proc(
    connection: GDBusConnection,
    senderName, objectPath, interfaceName, signalName: cstring,
    parameters: GVariant,
    userData: pointer
  ) {.cdecl.}

############################
# GLib Core
############################

proc g_free*(mem: pointer) {.cdecl, importc, dynlib: glibLib.}
proc g_error_free*(error: ptr GError) {.cdecl, importc, dynlib: glibLib.}
proc g_main_context_iteration*(context: pointer, mayBlock: cint): cint {.cdecl, importc, dynlib: glibLib.}
proc g_timeout_add_seconds*(interval: cuint, function: GSourceFunc, data: pointer): cuint {.cdecl, importc, dynlib: glibLib.}
proc g_source_remove*(tag: cuint): cint {.cdecl, importc, dynlib: glibLib.}
proc g_object_unref*(obj: pointer) {.cdecl, importc, dynlib: gobjectLib.}

############################
# GVariant
############################

proc g_variant_new*(format: cstring): GVariant {.cdecl, importc, dynlib: glibLib, varargs.}
proc g_variant_new_string*(value: cstring): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_new_uint32*(value: uint32): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_new_boolean*(value: cint): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_new_int32*(value: int32): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_new_object_path*(value: cstring): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_new_variant*(value: GVariant): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_get_int32*(value: GVariant): int32 {.cdecl, importc, dynlib: glibLib.}
proc g_variant_get*(value: GVariant, format: cstring) {.cdecl, importc, dynlib: glibLib, varargs.}
proc g_variant_get_child_value*(value: GVariant, index: csize_t): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_n_children*(value: GVariant): csize_t {.cdecl, importc, dynlib: glibLib.}
proc g_variant_get_uint32*(value: GVariant): uint32 {.cdecl, importc, dynlib: glibLib.}
proc g_variant_get_string*(value: GVariant, length: ptr csize_t): cstring {.cdecl, importc, dynlib: glibLib.}
proc g_variant_get_variant*(value: GVariant): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_lookup_value*(dictionary: GVariant, key: cstring, expectedType: pointer): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_unref*(value: GVariant) {.cdecl, importc, dynlib: glibLib.}
proc g_variant_builder_new*(variantType: pointer): GVariantBuilder {.cdecl, importc, dynlib: glibLib.}
proc g_variant_builder_add*(builder: GVariantBuilder, format: cstring) {.cdecl, importc, dynlib: glibLib, varargs.}
proc g_variant_builder_end*(builder: GVariantBuilder): GVariant {.cdecl, importc, dynlib: glibLib.}
proc g_variant_builder_unref*(builder: GVariantBuilder) {.cdecl, importc, dynlib: glibLib.}

############################
# GDBus
############################

proc g_dbus_address_get_for_bus_sync*(busType: cint, cancellable: pointer,
  error: ptr ptr GError): cstring {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_new_for_address_sync*(address: cstring, flags: cint, observer: pointer,
  cancellable: pointer, error: ptr ptr GError): GDBusConnection {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_get_unique_name*(connection: GDBusConnection): cstring {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_call_sync*(connection: GDBusConnection,
  busName, objectPath, interfaceName, methodName: cstring,
  parameters: GVariant, replyType: pointer, flags: cint, timeoutMs: cint,
  cancellable: pointer, error: ptr ptr GError): GVariant {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_call_with_unix_fd_list_sync*(connection: GDBusConnection,
  busName, objectPath, interfaceName, methodName: cstring,
  parameters: GVariant, replyType: pointer, flags: cint, timeoutMs: cint,
  fdList: GUnixFDList, outFdList: ptr GUnixFDList,
  cancellable: pointer, error: ptr ptr GError): GVariant {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_signal_subscribe*(connection: GDBusConnection,
  sender, interfaceName, member, objectPath, arg0: cstring, flags: cint,
  callback: GDBusSignalCallback, userData: pointer, userDataFreeFunc: pointer): cuint {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_emit_signal*(connection: GDBusConnection,
  destination, objectPath, interfaceName, signalName: cstring,
  parameters: GVariant, error: ptr ptr GError): cint {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_connection_register_object*(connection: GDBusConnection, objectPath: cstring,
  interfaceInfo: pointer, vtable: ptr GDBusInterfaceVTable, userData: pointer,
  userDataFreeFunc: pointer, error: ptr ptr GError): cuint {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_node_info_new_for_xml*(xml: cstring, error: ptr ptr GError): pointer {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_node_info_lookup_interface*(info: pointer, name: cstring): pointer {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_method_invocation_return_value*(invocation: pointer, parameters: GVariant) {.cdecl, importc, dynlib: gioLib.}
proc g_dbus_method_invocation_return_dbus_error*(invocation: pointer,
  errorName, errorMessage: cstring) {.cdecl, importc, dynlib: gioLib.}
proc g_unix_fd_list_get*(list: GUnixFDList, index: cint, error: ptr ptr GError): cint {.cdecl, importc, dynlib: gioLib.}

############################
# Nim Helpers
############################

proc takeErrorMessage*(error: var ptr GError, fallback: string): string =
  # Convert and free a GError in one step so callers cannot leak it.
  if error.isNil:
    return fallback
  result = if error.message.isNil: fallback else: $error.message
  g_error_free(error)
  error = nil

proc variantType*(signature: static string): pointer =
  # G_VARIANT_TYPE() is a plain cast in C; string literals live for the whole program.
  cast[pointer](cstring(signature))
