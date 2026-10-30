import std/posix

# Runs helper programs (fc-match, wl-copy, wl-paste) and starts Inkpane for inkpane-mcp,
# with plain fork and exec. Nim's osproc does much more than Inkpane needs and is a
# sizeable part of a small binary.

proc run*(args: openArray[string], input = "", output = false): tuple[code: int, text: string] =
  ## Runs args[0], found on PATH, with `input` on its stdin; with `output`, collects its
  ## stdout. code is the exit status, -1 when it could not run.
  var stdinPipe, stdoutPipe: array[2, cint]
  if pipe(stdinPipe) != 0:
    return (-1, "")
  if output and pipe(stdoutPipe) != 0:
    discard close(stdinPipe[0])
    discard close(stdinPipe[1])
    return (-1, "")
  signal(SIGPIPE, SIG_IGN)   # a helper that exits early must not take Inkpane with it
  let argv = allocCStringArray(args)   # before fork: the child may only exec
  defer: deallocCStringArray(argv)
  let pid = fork()
  if pid == 0:
    discard dup2(stdinPipe[0], 0)
    if output:
      discard dup2(stdoutPipe[1], 1)
    discard close(stdinPipe[0])
    discard close(stdinPipe[1])
    if output:
      discard close(stdoutPipe[0])
      discard close(stdoutPipe[1])
    discard execvp(argv[0], argv)
    exitnow(127)
  discard close(stdinPipe[0])
  if output:
    discard close(stdoutPipe[1])
  if pid < 0:
    discard close(stdinPipe[1])
    if output: discard close(stdoutPipe[0])
    return (-1, "")
  var written = 0
  while written < input.len:
    let n = write(stdinPipe[1], input[written].unsafeAddr, input.len - written)
    if n <= 0: break
    written += n
  discard close(stdinPipe[1])
  if output:
    var buffer: array[4096, char]
    while true:
      let n = read(stdoutPipe[0], buffer[0].addr, buffer.len)
      if n <= 0: break
      let start = result.text.len
      result.text.setLen(start + n)
      copyMem(result.text[start].addr, buffer[0].addr, n)
    discard close(stdoutPipe[0])
  var status: cint
  if waitpid(pid, status, 0) < 0 or not WIFEXITED(status):
    result.code = -1
  else:
    result.code = WEXITSTATUS(status)

proc detach*(args: openArray[string]): bool =
  ## Starts args[0], found on PATH, in its own session so it outlives us; false when it
  ## could not be started. The middle child exits at once, so nothing is left to reap.
  ## Its stdin, stdout and stderr are /dev/null: never our pipes, which close when we exit.
  let argv = allocCStringArray(args)
  defer: deallocCStringArray(argv)
  let pid = fork()
  if pid == 0:
    discard setsid()
    if fork() == 0:
      let null = open("/dev/null", O_RDWR)
      for fd in 0.cint .. 2.cint:
        discard dup2(null, fd)
      if null > 2: discard close(null)
      discard execvp(argv[0], argv)
      exitnow(127)
    exitnow(0)
  var status: cint
  pid > 0 and waitpid(pid, status, 0) == pid
