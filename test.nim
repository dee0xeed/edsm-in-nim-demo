
import posix
import edsm

proc sm_work_T0(me, src: ptr StageMachine, data: pointer)
proc sm_work_D0(me, src: ptr StageMachine, data: pointer)
proc sm_work_S0(me, src: ptr StageMachine, data: pointer)

proc sm_init_enter(me: ptr StageMachine) =
  me.addTimer()
  me.addIo(0)
  me.addSignal(EDSM_SIGINT)
  me.addSignal(EDSM_SIGTERM)

  let init = me.stages[0].addr
  let work = me.stages[1].addr

  init.addReflex(M0, work) # transition INIT->WORK

  work.addReflex(me.timers[0], sm_work_T0)  # action on timer 0
  work.addReflex(me.signals[0], sm_work_S0) # action on signal 0 (ctrl-c, SIGINT)
  work.addReflex(me.signals[1], sm_work_S0) # same action on signal 1 (SIGTERM)
  work.addReflex(me.io[0], D0, sm_work_D0)

  Message(src: me, dst: me, code: M0.uint8).`>--`

proc sm_work_enter(me: ptr StageMachine) =
  echo "Hello!"
  me.signals[0].enable
  me.signals[1].enable
  me.timers[0].start(500.msec)
  me.io[0].enable

proc sm_work_T0(me, src: ptr StageMachine, data: pointer) =
  var tc = me.timers[0].data.timerData.tickCount
  if 0 == (tc and 1):
    echo "tick!"
  else:
    echo "tock!"
  tc = tc + 1
  me.timers[0].data.timerData.tickCount = tc
  me.timers[0].start(500.msec)

proc sm_work_D0(me, src: ptr StageMachine, data: pointer) =
  echo "sm_work_D0"
  echo me.io[0].data.ioData.bytesAvail, " bytes available"
  var buf: array[1024, uint8]
  let r = read(me.io[0].id, buf.addr, 1024)
  echo "read ", r, " bytes"
  me.io[0].enable

proc sm_work_S0(me, src: ptr StageMachine, data: pointer) =
  # this will terminate event loop (dst is nil)
  Message(src: me).`>--`

proc sm_work_leave(me: ptr StageMachine) =
  echo "Goodbye!"

var sm = StageMachine(name: "the-machine")
sm.addStage("INIT", sm_init_enter)
sm.addStage("WORK", sm_work_enter, sm_work_leave)
sm.run

loop()
