
import deques,strutils
import posix,epoll

# these are not exported
proc timerfd_create(clock_id: ClockId, flags: cint): cint
  {.cdecl, importc: "timerfd_create", header: "<sys/timerfd.h>".}
proc timerfd_settime(ufd: cint, flags: cint, utmr: var Itimerspec, otmr: var Itimerspec): cint
  {.cdecl, importc: "timerfd_settime", header: "<sys/timerfd.h>".}
proc signalfd(fd: cint, mask: var Sigset, flags: cint): cint
  {.cdecl, importc: "signalfd", header: "<sys/signalfd.h>".}

const
  EDSM_SIGINT* = SIGINT
  EDSM_SIGTERM* = SIGTERM
  EDSM_FIONREAD = 0x541B

type
  Action = proc(me: ptr StageMachine, src: ptr StageMachine, data: pointer)
  EnterFunc = proc(me: ptr StageMachine)
  LeaveFunc = proc(me: ptr StageMachine)

  ReflexKind = enum rkAction, rkTransition
  EventSourceKind* = enum eskStageMachine, eskIo, eskSignal, eskTimer, eskLast
  InternalMessage* {.pure.} = enum M0, M1, M2, M3, M4, M5, M6, M7, M8
  IoMessage* {.pure.} = enum D0, D1, D2

  Reflex = object
    case kind: ReflexKind
    of rkAction: action: Action
    of rkTransition: nextStage: ptr Stage # just index?..

#  ReflexMatrix = array[eskLast, array[16, ptr Reflex]]
  # M0 M1 M2 ... M15 : internal messages
  # D0 D1 D2         : i/o (POLLIN, POLLOUT, POLLERR)
  # S0 S1 S2 ... S15 : signals
  # T0 T1 T2 ... T15 : timers
  ReflexArray = array[eskLast.int * 16, ptr Reflex] # just index?..

  Stage* = object
    name: string
    enter: EnterFunc # may be nil
    leave: LeaveFunc # may be nil
    reflexes*: seq[Reflex]
#    reflexMatrix: ReflexMatrix
    reflexArray: ReflexArray

  StageMachine* {.inheritable.} = object
    name*: string
    isRunning: bool
    stages*: seq[Stage]
    currentStage: ptr Stage
    timers*: seq[EventSource]
    signals*: seq[EventSource]
    io*: seq[EventSource]

  msec* = int
  TimerData = object
    tickCount*: int
    expireCount: clong

  IoData = object
    bytesAvail*: int
    isListeningSocket: bool

  EventSourceData = object
    case kind: EventSourceKind
    of eskStageMachine: notNeeded1: int
    of eskIo: ioData*: IoData
    of eskSignal: signalData: SigInfo
    of eskTimer: timerData*: TimerData
    of eskLast: notNeeded2: int

  EventSource = object
    id*: cint # fd
    seqn: uint8
    owner: ptr StageMachine
    data*: EventSourceData
    # NOTE: for timers and signals seqn is just... seqn
    # for i/o it has special meaning:
    # 0 - POLLIN, i.e. read()/accept() will not block
    # 1 - POLLOUT, i.e. write() will not block
    # 2 - POLLERR/POLLHUP/POLLRDHUP

  Message* = object
    src*: ptr StageMachine # nil for messages from OS
    dst*: ptr StageMachine # nil means 'exit event loop'
    code*: uint8 # hi nibble is esk, lo nibble is seqn, index for Stage.reflexArray
    data*: pointer # ptr EventSource for messages from OS

var
  deq: Deque[Message] # message queue
  epfd: cint # event queue (epoll)

proc putMsg*(m: Message) =
  deq.addLast(m)

proc getMsg(m: var Message): bool =
  if 0 == deq.len:
    return false
  m = deq.popFirst
  return true

# coooool...
proc `>--`*(m: Message) = putMsg(m)
proc `<--`(m: var Message): bool = getMsg(m)

proc addIo*(me: ptr StageMachine, fd: cint) =
  assert me.io.len == 0 # only ONE i/o channel per machine
  var esd = EventSourceData(kind: eskIo)
  var io = EventSource(id : fd, owner: me, data: esd)
  me.io.add(io)

proc addListeningSocket*(me: ptr StageMachine, port: uint16) =
  let sk = cint(socket(AF_INET, SOCK_STREAM, 0))
  assert -1 != sk
  var yes = 1.cint
  discard setsockopt(sk.SocketHandle, SOL_SOCKET, SO_REUSEADDR, yes.addr, yes.sizeof.SockLen)
  var myAddr: Sockaddr_in
  myAddr.sin_family = AF_INET.uint16
  myAddr.sin_port = htons(port)
  discard bindSocket(sk.SocketHandle, cast[ptr SockAddr](myAddr.addr), myAddr.sizeof.SockLen)
  discard listen(sk.SocketHandle, 128)
  addIo(me, sk)
  me.io[0].data.ioData.isListeningSocket = true

proc addSignal*(me: ptr StageMachine, signo: cint) =
  var ss, oldss: Sigset
  # block the signal
  discard sigemptyset(ss)
  discard sigaddset(ss, signo)
  discard sigprocmask(SIG_BLOCK, ss, oldss)
  let fd = signalfd(-1, ss, 0)
  let esd = EventSourceData(kind: eskSignal)
  let sg = EventSource(id : fd, owner: me, data: esd)
  me.signals.add(sg)
  me.signals[^1].seqn = me.signals.high.uint8

proc addTimer*(me: ptr StageMachine) =
  let fd = timerfd_create(CLOCK_REALTIME, 0)
  var esd = EventSourceData(kind: eskTimer)
  var tm = EventSource(id : fd, owner: me, data: esd)
  me.timers.add(tm)
  me.timers[^1].seqn = me.timers.high.uint8

proc enable*(esrc: var EventSource) =
  let m : uint32 = EPOLLIN or EPOLLRDHUP or EPOLLONESHOT
  var e = EpollEvent(events: m)
  e.data.u64 = cast[uint64](esrc.addr)
  var r = epoll_ctl(epfd, EPOLL_CTL_ADD, esrc.id, e.addr)
  if -1 == r:
    assert errno == EEXIST
    r = epoll_ctl(epfd, EPOLL_CTL_MOD, esrc.id, e.addr)
    assert r != -1

proc enableOut*(esrc: var EventSource) =
  let m : uint32 = EPOLLOUT or EPOLLONESHOT
  var e = EpollEvent(events: m)
  e.data.u64 = cast[uint64](esrc.addr)
  var r = epoll_ctl(epfd, EPOLL_CTL_ADD, esrc.id, e.addr)
  if -1 == r:
    assert errno == EEXIST
    r = epoll_ctl(epfd, EPOLL_CTL_MOD, esrc.id, e.addr)
    assert r != -1

proc start*(tm: var EventSource, interval: msec) =
  assert tm.data.kind == eskTimer
  var its, old: Itimerspec

  its.it_value.tv_sec = Time(interval div 1000)
  its.it_value.tv_nsec = (interval mod 1000) * 1000 * 1000
  let r = timerfd_settime(tm.id, 0, its, old)
  assert r == 0
  enable(tm)

proc stop*(tm: var EventSource) =
  assert tm.data.kind == eskTimer
  var its, old: Itimerspec
#  its.it_value.tv_sec = 0
#  its.it_value.tv_nsec = 0
  let r = timerfd_settime(tm.id, 0, its, old)
  assert r == 0

proc addReflex*(s: ptr Stage; es: EventSource; m: IoMessage; a: Action) =
  assert es.data.kind == eskIo
  let r = Reflex(kind: rkAction, action: a)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[(es.data.kind.uint8 shl 4) or m.uint8] = ra

proc addReflex*(s: ptr Stage; es: EventSource; m: IoMessage; ns: ptr Stage) =
  assert es.data.kind == eskIo
  assert s != ns
  let r = Reflex(kind: rkTransition, nextStage: ns)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[(es.data.kind.uint8 shl 4) or m.uint8] = ra

proc addReflex*(s: ptr Stage; es: EventSource; a: Action) =
  let r = Reflex(kind: rkAction, action: a)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[(es.data.kind.uint8 shl 4) or es.seqn] = ra

proc addReflex*(s: ptr Stage, es: EventSource, ns: ptr Stage) =
  assert s != ns
  let r = Reflex(kind: rkTransition, nextStage: ns)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[(es.data.kind.uint8 shl 4) or es.seqn] = ra

proc addReflex*(s: ptr Stage; im: InternalMessage; a: Action) =
  let r = Reflex(kind: rkAction, action: a)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[im.uint8] = ra

proc addReflex*(s: ptr Stage, im: InternalMessage, ns: ptr Stage) =
  assert s != ns
  let r = Reflex(kind: rkTransition, nextStage: ns)
  s.reflexes.add(r)
  let ra = s.reflexes[^1].addr
  s.reflexArray[im.uint8] = ra

proc addStage*(me: var StageMachine, sn: string, ef: EnterFunc = nil, lf: LeaveFunc = nil) =
  let s = Stage(name: sn, enter: ef, leave: lf)
  me.stages.add(s)

proc run*(me: var StageMachine) =
  assert(me.isRunning == false)
  assert(me.stages.len > 0)
  me.currentStage = me.stages[0].addr
  let s = me.stages[0]
  if (s.enter != nil): s.enter(me.addr)

proc reactTo(me: ptr StageMachine, msg: Message) =
  var s = me.currentStage
  var r = s.reflexArray[msg.code]
  assert r != nil

  # action
  if r.kind == rkAction:
    r.action(me, msg.src, msg.data)
    return

  # transition
  if s.leave != nil: s.leave(me)
  let nextStage = r.nextStage
  me.currentStage = nextStage
  if nextStage.enter != nil: nextStage.enter(me)

proc getEventInfo(esrc: ptr EventSource, events: uint32): uint8 =
  if 0 != (events and (EPOLLERR or EPOLLHUP or EPOLLRDHUP)):
    return D2.uint8
  case esrc.data.kind:
  of eskTimer:
    let r = read(esrc.id, esrc.data.timerData.expireCount.addr, 8)
    assert 8 == r
    if esrc.data.timerData.expireCount > 1:
      echo "timer #", esrc.seqn, " overrun!"
      echo "(expireCount = ", esrc.data.timerData.expireCount, ")"
    return esrc.seqn
  of eskSignal:
    let r = read(esrc.id, esrc.data.signalData.addr, SigInfo.sizeof)
    assert SigInfo.sizeof == r
    echo ""
    echo r, " ", SigInfo.sizeof
    echo "got signal ", esrc.data.signalData.si_signo, " from PID ", esrc.data.signalData.si_pid
    #echo esrc.data.signalData.si_code, " ", esrc.data.signalData.si_errno
    return esrc.seqn
  of eskIo:
    if 0 != (events and EPOLLOUT):
      return D1.uint8
    # EPOLLIN
    if not esrc.data.ioData.isListeningSocket:
      let r = ioctl(esrc.id, EDSM_FIONREAD, esrc.data.ioData.bytesAvail.addr)
      assert r != -1
    return D0.uint8
  else:
    discard

# message dispatcher and event loop
proc loop*() =
  block outer:
    while true:
      var msg: Message
      while msg.`<--`:
        if msg.dst.isNil:
          if not msg.src.isNil:
            var f = msg.src.currentStage.leave
            if not f.isNil: f(msg.src)
          break outer

        let dst = msg.dst
        let src = msg.src
        let srcName = if src == nil: "OS" else:
          if msg.src == msg.dst: "SELF" else: src.name
        echo dst.name, " @ ", dst.currentStage.name, " got code 0x", msg.code.toHex, " from ", srcName

        msg.dst.reactTo(msg)

      var e : EpollEvent
      let n = epoll_wait(epfd, e.addr, 1.cint, -1.cint)
      assert(n == 1)
      let s = cast[ptr EventSource](e.data)
      let seqn = getEventInfo(s, e.events)
      let c: uint8 = (s.data.kind.uint8 shl 4) or seqn
      Message(src: nil, dst: s.owner, code: c, data: s).`>--`

epfd = epoll_create1(0)
if -1 == epfd: echo "epoll_create1(): " & $strerror(errno)
assert epfd > 0
