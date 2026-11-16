package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

const prSetChildSubreaper = 36

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
		logf("warning: PR_SET_CHILD_SUBREAPER failed: %v", errno)
	}

	sigs := make(chan os.Signal, 32)
	signal.Notify(sigs, append([]os.Signal{syscall.SIGCHLD}, forwarded...)...)

	path, err := exec.LookPath(args[0])
	if err != nil {
		logf("%v", err)
		os.Exit(127)
	}
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

func reap(childPid int) (code int, done bool) {
	for {
		var ws syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
		if err == syscall.EINTR {
			continue
		}
		if pid <= 0 || err != nil {
			return code, done
		}
		if pid != childPid {
			continue
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
