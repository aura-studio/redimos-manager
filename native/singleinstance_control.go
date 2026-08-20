package main

import (
	"bufio"
	"errors"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

var (
	errNoControlServer = errors.New("lock file carries no control port (older holder build)")
	errBadAck          = errors.New("holder did not acknowledge the activate request")
)

// startControlServer binds a loopback-only listener that serves the
// "activate" handoff for future contenders and returns its port. It lives in
// the lock holder's process for the process lifetime; the OS closes it on
// any kind of exit. Port 0 means "handoff unavailable" — contenders fall
// back to the load-error screen.
func startControlServer() int {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go handleControlConn(c)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func handleControlConn(c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err == nil && strings.HasPrefix(line, "activate") {
		// platformActivate runs in the HOLDER's process — it brings this
		// manager's own window to the front.
		platformActivate()
		_, _ = c.Write([]byte("ok\n"))
	}
}

// signalRunningInstance reads the holder's pid+port from the lock file and
// asks it to come to the front. The holder publishes the pair moments after
// taking the lock, so a short grace period covers a freshly-started holder.
func signalRunningInstance(path string) error {
	var port int
	for i := 0; i < 20 && port == 0; i++ {
		if i > 0 {
			time.Sleep(50 * time.Millisecond)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		fields := strings.Fields(string(data))
		if len(fields) < 2 {
			continue
		}
		port, _ = strconv.Atoi(fields[1])
	}
	if port == 0 {
		return errNoControlServer
	}
	c, err := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(port), 500*time.Millisecond)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Write([]byte("activate\n")); err != nil {
		return err
	}
	ack := make([]byte, 8)
	n, err := c.Read(ack)
	if err != nil || !strings.HasPrefix(string(ack[:n]), "ok") {
		return errBadAck
	}
	return nil
}
