
import posix
import edsm
import deques
import algorithm

const

  bufSize = 32

type

  Client = object
     sk : cint

  WorkerMachine = object of StageMachine
    rxBuf: array[bufSize, char]
    txBuf: array[bufSize, char]
    bytes: int
    wPool: ptr Deque[ptr WorkerMachine]
    client: ptr Client
    reception: ptr ListenMachine

  ListenMachine = object of StageMachine
    tcpPort: uint16
    maxClients: Natural
    nClients: Natural
    workerPool: ptr Deque[ptr WorkerMachine]

proc receptionWorkD0(self, src: ptr StageMachine, data: pointer)
proc receptionWorkS0(self, src: ptr StageMachine, data: pointer)
proc receptionWorkM0(self, src: ptr StageMachine, data: pointer)

proc receptionInitEnter(self: ptr StageMachine) =
  let me = cast[ptr ListenMachine](self)
  me.addListeningSocket(me.tcpPort)
  me.addSignal(EDSM_SIGINT)
  me.addSignal(EDSM_SIGTERM)

  let init = me.stages[0].addr
  let work = me.stages[1].addr

  init.addReflex(M0, work)
  work.addReflex(me.signals[0], receptionWorkS0)
  work.addReflex(me.signals[1], receptionWorkS0)
  work.addReflex(me.io[0], D0, receptionWorkD0)
  work.addReflex(M0, receptionWorkM0)
  Message(src: me, dst: me, code: M0.uint8).`>--`

proc receptionWorkEnter(self: ptr StageMachine) =
  let me = cast[ptr ListenMachine](self)
  echo "Hello! I'm simple EDSM-based echo-server listening on port ", me.tcpPort
  me.signals[0].enable
  me.signals[1].enable
  me.io[0].enable

# new connection
proc receptionWorkD0(self, src: ptr StageMachine, data: pointer) =
  let me = cast[ptr ListenMachine](self)
  var peerAddr: Sockaddr_in
  var addrLength: SockLen = peerAddr.sizeof.SockLen
  let sk = cint(accept(me.io[0].id.SocketHandle, cast[ptr SockAddr](peerAddr.addr), addrLength.addr))
#  echo "sk = ", sk
  me.io[0].enable

  var cl = cast[ptr Client](alloc0(sizeof(Client)))
  cl.sk = sk
  if 0 == me.workerPool[].len:
    echo me.name, ": no workers available"
    Message(src: me, dst: me, code: M0.uint8, data: cl).`>--`
    return

  let worker = me.workerPool[].popFirst
  Message(src: me, dst: worker, code: M1.uint8, data: cl).`>--`

# message from worker (client gone) or from self (no workers were available)
proc receptionWorkM0(self, src: ptr StageMachine, data: pointer) =
  var cl = cast[ptr Client](data)
  discard close(cl.sk)
  dealloc(cl)

proc receptionWorkS0(self, src: ptr StageMachine, data: pointer) =
  # this will terminate event loop (dst is nil)
  Message(src: self).`>--`

proc receptionWorkLeave(me: ptr StageMachine) =
  echo "Goodbye!"

proc workerIdleM1(self, src: ptr StageMachine, data: pointer)
proc workerRecvD0(self, src: ptr StageMachine, data: pointer)
proc workerRecvT0(self, src: ptr StageMachine, data: pointer)
proc workerSendD1(self, src: ptr StageMachine, data: pointer)

proc workerInitEnter(me: ptr StageMachine) =
  me.addTimer() # for rx timeout
  me.addIo(-1)

  let init = me.stages[0].addr
  let idle = me.stages[1].addr
  let recv = me.stages[2].addr
  let send = me.stages[3].addr
  let done = me.stages[4].addr

  init.addReflex(M0, idle)

  idle.addReflex(M1, workerIdleM1)
  idle.addReflex(M0, recv)

  recv.addReflex(me.io[0], D0, workerRecvD0)
  recv.addReflex(me.io[0], D2, done)
  recv.addReflex(me.timers[0], workerRecvT0)
  recv.addReflex(M0, send)
  recv.addReflex(M2, done)

  send.addReflex(me.io[0], D1, workerSendD1)
  send.addReflex(me.io[0], D2, done)
  send.addReflex(M0, recv)

  done.addReflex(M0, idle)
  Message(src: me, dst: me, code: M0.uint8).`>--`

proc workerIdleEnter(self: ptr StageMachine) =
  let me = cast[ptr WorkerMachine](self)
  me.wPool[].addLast(me)

# message from reception machine, new client
proc workerIdleM1(self, src: ptr StageMachine, data: pointer) =
  var me = cast[ptr WorkerMachine](self)
  me.client = cast[ptr Client](data)
  me.reception = cast[ptr ListenMachine](src)
  me.io[0].id = me.client.sk
  Message(src: me, dst: me, code: M0.uint8).`>--`

proc workerRecvEnter(self: ptr StageMachine) =
  var me = cast[ptr WorkerMachine](self)
  me.rxBuf.fill(0.char)
  me.bytes = 0
  me.io[0].enable
  me.timers[0].start(10000.msec)

proc workerRecvD0(self, src: ptr StageMachine, data: pointer) =
  let me = cast[ptr WorkerMachine](self)
  let n = me.io[0].data.ioData.bytesAvail

  if 0 == n: # account for EPOLLIN with no data
    echo me.name, ": no data"
    Message(src: me, dst: me, code: M2.uint8).`>--`
    return

  if n > bufSize:
    echo me.name, ": too much data"
    Message(src: me, dst: me, code: M2.uint8).`>--`
    return

  let r = read(me.io[0].id, me.rxBuf.addr, n)
  echo me.name, ": ", r, " bytes in"
  me.bytes = n
  Message(src: me, dst: me, code: M0.uint8).`>--`

proc workerRecvT0(self, src: ptr StageMachine, data: pointer) =
  let me = cast[ptr WorkerMachine](self)
  echo me.name, ": RX timeout!"
  Message(src: me, dst: me, code: M2.uint8).`>--`

proc workerRecvLeave(me: ptr StageMachine) =
   me.timers[0].stop

proc workerSendEnter(self: ptr StageMachine) =
  let me = cast[ptr WorkerMachine](self)
  me.txBuf = me.rxBuf
  me.io[0].enableOut

proc workerSendD1(self, src: ptr StageMachine, data: pointer) =
  let me = cast[ptr WorkerMachine](self)
  let r = write(me.io[0].id, me.txBuf.addr, me.bytes)
  echo me.name, ": ", r, " bytes out"
  Message(src: me, dst: me, code: M0.uint8).`>--`

proc workerDoneEnter(self: ptr StageMachine) =
  let me = cast[ptr WorkerMachine](self)
  echo me.name, ": client gone"
  Message(src: me, dst: me, code: M0.uint8).`>--`
  Message(src: me, dst: me.reception, code: M0.uint8, data: me.client).`>--`

var reception = ListenMachine(name: "RECEPTION", tcpPort: 1111, maxClients: 4)
var workers = newSeq[WorkerMachine](reception.maxClients)
var workerPool = initDeque[ptr WorkerMachine](reception.maxClients)

var worker: WorkerMachine

for k in 0 ..< reception.maxClients:
  worker = WorkerMachine(name: "WORKER-" & $k)
  worker.wPool = workerPool.addr
  worker.addStage("INIT", workerInitEnter)
  worker.addStage("IDLE", workerIdleEnter)
  worker.addStage("RECV", workerRecvEnter, workerRecvLeave)
  worker.addStage("SEND", workerSendEnter)
  worker.addStage("DONE", workerDoneEnter)
  workers[k] = worker

echo "we have ", workers.len, " workers"

for worker in workers.mitems:
  worker.run

reception.workerPool = workerPool.addr
reception.addStage("INIT", receptionInitEnter)
reception.addStage("WORK", receptionWorkEnter, receptionWorkLeave)
reception.run

loop()
