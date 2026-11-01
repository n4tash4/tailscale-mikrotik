// ts-init is a minimal PID 1 for the tailscale-mikrotik container.
//
// Why not tini/dumb-init/catatonit: RouterOS decides how to stop a container
// by looking at whether PID 1 has a *handler installed* for the stop-signal
// (SigCgt in /proc/1/status). If not, it logs "signal 15 (Terminated) not
// caught, kill immediately" and sends SIGKILL. Those inits block signals and
// collect them with sigtimedwait/signalfd, so SigCgt is empty and RouterOS
// never lets them shut down gracefully. Go's os/signal installs real
// sigaction handlers, so RouterOS sees SIGTERM as caught.
//
// Behaviour (tini-compatible, no flags):
//
//		ts-init [--] command [args...]
//
//	  - starts command as its only direct child, inheriting stdio and env
//	  - forwards SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGWINCH
//	    to the child (not its process group; tailscale.sh's trap stops its own
//	    children)
//	  - reaps every exited process, including orphans reparented to it
//	  - exits when the child exits: with its exit code, or 128+signal if it
//	    was killed by a signal
//	  - sets PR_SET_CHILD_SUBREAPER so orphans are still reaped if it is ever
//	    run as something other than PID 1
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

// prSetChildSubreaper is PR_SET_CHILD_SUBREAPER from <linux/prctl.h>.
const prSetChildSubreaper = 36

// forwarded are the signals passed through to the child.
var forwarded = []os.Signal{
	syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT,
	syscall.SIGUSR1, syscall.SIGUSR2, syscall.SIGWINCH,
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ts-init: "+format+"\n", args...)
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		logf("usage: ts-init [--] command [args...]")
		os.Exit(2)
	}

	if _, _, errno := syscall.RawSyscall(syscall.SYS_PRCTL, prSetChildSubreaper, 1, 0); errno != 0 {
		// Not fatal: as PID 1 we inherit orphans anyway.
		logf("warning: PR_SET_CHILD_SUBREAPER failed: %v", errno)
	}

	// Register handlers BEFORE starting the child so no signal is lost and
	// SigCgt is populated from the moment RouterOS could look at it.
	// SIGCHLD wakes the reaper; the channel is buffered and signals coalesce,
	// so each wake-up reaps everything that has exited.
	sigs := make(chan os.Signal, 32)
	signal.Notify(sigs, append([]os.Signal{syscall.SIGCHLD}, forwarded...)...)

	path, err := exec.LookPath(args[0])
	if err != nil {
		logf("%v", err)
		os.Exit(127)
	}
	// os.StartProcess (not exec.Cmd): we must never Wait on the child through
	// os/exec, because the reaper below collects it via wait4(-1) and the two
	// would race for the same exit status.
	child, err := os.StartProcess(path, args, &os.ProcAttr{
		Env:   os.Environ(),
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
	})
	if err != nil {
		logf("start %s: %v", path, err)
		os.Exit(126)
	}
	childPid := child.Pid

	for sig := range sigs {
		if sig != syscall.SIGCHLD {
			s := sig.(syscall.Signal)
			if err := syscall.Kill(childPid, s); err != nil && err != syscall.ESRCH {
				logf("forward %v to %d: %v", s, childPid, err)
			}
			continue
		}
		if code, done := reap(childPid); done {
			os.Exit(code)
		}
	}
}

// reap collects every exited process without blocking. It returns the exit
// code to use and done=true once the main child has been collected.
func reap(childPid int) (code int, done bool) {
	for {
		var ws syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
		if err == syscall.EINTR {
			continue
		}
		if pid <= 0 || err != nil {
			// 0 = children exist but none exited; ECHILD = no children left.
			return code, done
		}
		if pid != childPid {
			continue // orphan reaped
		}
		done = true
		switch {
		case ws.Exited():
			code = ws.ExitStatus()
		case ws.Signaled():
			code = 128 + int(ws.Signal())
		default:
			code = 1
		}
	}
}
