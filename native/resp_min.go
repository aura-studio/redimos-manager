package main

// Minimal blocking RESP client for the Playground's `redis` host object. The
// Dart side has its own resp_client; the Go core had none, so this is a small
// self-contained one used only to run user Playground scripts against a running
// redimos proxy on 127.0.0.1:<port>. Not a general-purpose client.

import (
	"bufio"
	"fmt"
	"net"
	"strconv"
	"time"
)

type respConn struct {
	c  net.Conn
	br *bufio.Reader
}

func respDial(addr string, timeout time.Duration) (*respConn, error) {
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	return &respConn{c: c, br: bufio.NewReader(c)}, nil
}

func (r *respConn) close() {
	if r.c != nil {
		_ = r.c.Close()
	}
}

// cmd sends one command (all args as bulk strings) and returns the parsed reply:
// string | int64 | nil | []interface{}, or an error for a -ERR reply / transport
// failure.
func (r *respConn) cmd(args ...string) (interface{}, error) {
	var b []byte
	b = append(b, '*')
	b = strconv.AppendInt(b, int64(len(args)), 10)
	b = append(b, '\r', '\n')
	for _, a := range args {
		b = append(b, '$')
		b = strconv.AppendInt(b, int64(len(a)), 10)
		b = append(b, '\r', '\n')
		b = append(b, a...)
		b = append(b, '\r', '\n')
	}
	if _, err := r.c.Write(b); err != nil {
		return nil, err
	}
	return r.readReply()
}

func (r *respConn) readLine() (string, error) {
	line, err := r.br.ReadString('\n')
	if err != nil {
		return "", err
	}
	// strip trailing \r\n
	for len(line) > 0 && (line[len(line)-1] == '\n' || line[len(line)-1] == '\r') {
		line = line[:len(line)-1]
	}
	return line, nil
}

func (r *respConn) readReply() (interface{}, error) {
	prefix, err := r.br.ReadByte()
	if err != nil {
		return nil, err
	}
	switch prefix {
	case '+': // simple string
		return r.readLine()
	case '-': // error
		line, _ := r.readLine()
		return nil, fmt.Errorf("%s", line)
	case ':': // integer
		line, err := r.readLine()
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(line, 10, 64)
	case '$': // bulk string
		line, err := r.readLine()
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(line)
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil // null bulk
		}
		buf := make([]byte, n+2) // + CRLF
		if _, err := readFull(r.br, buf); err != nil {
			return nil, err
		}
		return string(buf[:n]), nil
	case '*': // array
		line, err := r.readLine()
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(line)
		if err != nil {
			return nil, err
		}
		if n < 0 {
			return nil, nil
		}
		out := make([]interface{}, n)
		for i := 0; i < n; i++ {
			v, err := r.readReply()
			if err != nil {
				return nil, err
			}
			out[i] = v
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unexpected RESP prefix %q", prefix)
	}
}

func readFull(br *bufio.Reader, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := br.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}
