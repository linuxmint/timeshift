package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"

	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

// Method is one callable operation.
type Method struct {
	// ReadOnly marks a method a group member may call. Anything that changes
	// state leaves this false and is root-only.
	ReadOnly bool

	// Fn does the work. Returning an *Error sends that; any other error
	// becomes an internal error with its message.
	Fn func(ctx context.Context, c *Conn, params json.RawMessage) (any, error)
}

// Server accepts clients on the unix socket.
type Server struct {
	// Path is the socket to listen on.
	Path string

	// GroupGID is granted read-only access; -1 for root-only. It sets the
	// socket's group owner and, unless Authorize is supplied, its policy.
	GroupGID int

	// Authorize decides what each peer may do. Nil uses
	// DefaultAuthorizer(GroupGID).
	Authorize Authorizer

	// Methods is the dispatch table.
	Methods map[string]Method

	// Queue is where subscriptions come from.
	Queue *jobs.Queue

	Log *slog.Logger

	listener net.Listener

	// activated records that the listener came from systemd, which owns the
	// socket file and must be the one to remove it.
	activated bool
	wg        sync.WaitGroup

	mu     sync.Mutex
	conns  map[*Conn]struct{}
	closed bool
}

// Conn is one client connection.
//
// Responses and events share the socket, so every write goes through one mutex.
// Without it a large event could be interleaved into the middle of a response
// and both would be unparseable.
type Conn struct {
	Peer Peer

	srv *Server
	c   net.Conn
	enc *json.Encoder
	wmu sync.Mutex

	subMu sync.Mutex
	subs  []*jobs.Subscription
}

// Listen creates the socket and starts accepting.
//
// The socket is created with a restrictive umask and then chmod-ed, so there is
// no window in which it is world-writable.
func (s *Server) Listen() error {
	if s.Log == nil {
		s.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	s.conns = map[*Conn]struct{}{}

	/* Prefer a socket systemd already bound for us.
	 *
	 * Binding our own while systemd holds one at the same path would replace
	 * the socket it is queueing connections on, and the connection that
	 * triggered the activation would be dropped. systemd has also already
	 * applied SocketMode/SocketUser/SocketGroup, so none of the mkdir, unlink,
	 * umask, chown or chmod below applies -- doing any of it would be
	 * second-guessing the unit file.
	 */
	if lns, err := ListenersFromSystemd(); err != nil {
		return err
	} else if len(lns) > 0 {
		for _, extra := range lns[1:] {
			extra.Close() // one socket unit, one listener
		}
		s.listener = lns[0]
		s.activated = true
		s.Log.Info("listening on a socket passed by systemd", "socket", s.Path)
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(s.Path), 0755); err != nil {
		return fmt.Errorf("ipc: mkdir %s: %w", filepath.Dir(s.Path), err)
	}
	// A socket left behind by a killed daemon would make bind fail.
	if err := os.Remove(s.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("ipc: remove stale socket: %w", err)
	}

	old := syscallUmask(0177) // 0600 until the chmod below widens it
	ln, err := net.Listen("unix", s.Path)
	syscallUmask(old)
	if err != nil {
		return fmt.Errorf("ipc: listen %s: %w", s.Path, err)
	}
	s.listener = ln

	mode := os.FileMode(0600)
	if s.GroupGID >= 0 {
		// Group members need to connect; the group itself is the access
		// control, so 0660 with the right group owner is the whole story.
		if err := os.Chown(s.Path, 0, s.GroupGID); err == nil {
			mode = 0660
		}
	}
	if err := os.Chmod(s.Path, mode); err != nil {
		ln.Close()
		return fmt.Errorf("ipc: chmod socket: %w", err)
	}

	s.Log.Info("listening", "socket", s.Path, "mode", mode.String(), "group_gid", s.GroupGID)
	return nil
}

// Serve accepts connections until the listener is closed.
func (s *Server) Serve() error {
	for {
		c, err := s.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		/* Add under the same lock that sets `closed`, so no Add can begin
		 * after Close has started waiting. A WaitGroup whose counter goes from
		 * zero to one concurrently with Wait is a documented misuse, and the
		 * race detector says so. */
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			c.Close()
			continue
		}
		s.wg.Add(1)
		s.mu.Unlock()

		go func() {
			defer s.wg.Done()
			s.handle(c)
		}()
	}
}

// Close stops listening and waits for in-flight connections.
func (s *Server) Close() error {
	if s.listener != nil {
		s.listener.Close()
	}
	s.mu.Lock()
	s.closed = true
	for c := range s.conns {
		c.c.Close()
	}
	s.mu.Unlock()

	// Safe now: `closed` is set, so Serve cannot start another handler.
	s.wg.Wait()

	/* The socket file is ours to remove only when we created it.
	 *
	 * Under socket activation systemd owns it and is still listening on its
	 * own descriptor: unlinking it here would leave systemd holding a socket
	 * with no name, so the next client would find nothing to connect to and
	 * activation would never fire again -- until the socket unit was
	 * restarted by hand. */
	if !s.activated {
		os.Remove(s.Path)
	}
	return nil
}

func (s *Server) handle(raw net.Conn) {
	defer raw.Close()

	unixConn, ok := raw.(*net.UnixConn)
	if !ok {
		return
	}

	peer, err := peerCreds(unixConn)
	if err != nil {
		s.Log.Warn("could not read peer credentials", "err", err)
		return
	}
	authorize := s.Authorize
	if authorize == nil {
		authorize = DefaultAuthorizer(s.GroupGID)
	}
	peer, err = authorize(peer)
	if err != nil {
		s.Log.Warn("refused connection", "err", err)
		return
	}

	c := &Conn{Peer: peer, srv: s, c: raw, enc: json.NewEncoder(raw)}

	s.mu.Lock()
	if s.closed {
		/* Accepted while shutting down. Close() has already walked s.conns, so
		 * a connection registered now would never be closed and its client
		 * would wait for an EOF that never comes. */
		s.mu.Unlock()
		return
	}
	s.conns[c] = struct{}{}
	s.mu.Unlock()
	defer func() {
		c.closeSubs()
		s.mu.Lock()
		delete(s.conns, c)
		s.mu.Unlock()
	}()

	s.Log.Debug("client connected", "peer", peer.String())

	sc := bufio.NewScanner(raw)
	// A params blob can be large -- an exclude list, a mount plan.
	sc.Buffer(make([]byte, 0, 64*1024), 4<<20)

	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			c.respond(Response{Error: Errf(CodeBadRequest, "malformed request: %v", err)})
			continue
		}
		c.dispatch(req)
	}
	s.Log.Debug("client disconnected", "peer", peer.String())
}

func (c *Conn) dispatch(req Request) {
	m, ok := c.srv.Methods[req.Method]
	if !ok {
		c.respond(Response{ID: req.ID, Error: Errf(CodeUnknownMethod, "no method %q", req.Method)})
		return
	}
	if c.Peer.ReadOnly && !m.ReadOnly {
		/* The whole point of the read-only tier: a group member may watch a
		 * backup, but starting or deleting one still needs root. */
		c.respond(Response{ID: req.ID, Error: Errf(CodeDenied,
			"%q requires root; this connection is read-only", req.Method)})
		return
	}

	result, err := m.Fn(context.Background(), c, req.Params)
	if err != nil {
		var ipcErr *Error
		if errors.As(err, &ipcErr) {
			c.respond(Response{ID: req.ID, Error: ipcErr})
			return
		}
		c.respond(Response{ID: req.ID, Error: Errf(CodeInternal, "%v", err)})
		return
	}
	c.respond(Response{ID: req.ID, Result: result})
}

func (c *Conn) respond(r Response) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if err := c.enc.Encode(r); err != nil {
		c.srv.Log.Debug("write failed", "peer", c.Peer.String(), "err", err)
	}
}

// SendEvent writes an event to this client.
func (c *Conn) SendEvent(e jobs.Event) {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if err := c.enc.Encode(e); err != nil {
		c.srv.Log.Debug("event write failed", "peer", c.Peer.String(), "err", err)
	}
}

// Subscribe attaches this connection to the event stream and pumps events onto
// the socket until the client goes away.
func (c *Conn) Subscribe(sub *jobs.Subscription) {
	c.subMu.Lock()
	c.subs = append(c.subs, sub)
	c.subMu.Unlock()

	go func() {
		for e := range sub.C {
			c.SendEvent(e)
		}
	}()
}

func (c *Conn) closeSubs() {
	c.subMu.Lock()
	subs := c.subs
	c.subs = nil
	c.subMu.Unlock()
	for _, s := range subs {
		s.Close()
	}
}
