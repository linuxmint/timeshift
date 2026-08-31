package ipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/makeafide/timeshift/src-go/internal/jobs"
)

// ErrNoDaemon means the socket is not there. Callers distinguish it because it
// is the one failure worth acting on: start the daemon, or explain that it is
// not running, rather than reporting a generic connection error.
var ErrNoDaemon = errors.New("ipc: timeshiftd is not running")

// Client is a connection to the daemon.
//
// One reader goroutine demultiplexes the socket: responses go to whoever is
// waiting on that id, events go to the event channel. Sharing one connection
// for both is what lets a client submit a job and then watch it without a
// second round trip or a second socket.
type Client struct {
	conn net.Conn
	enc  *json.Encoder

	nextID atomic.Int64

	mu      sync.Mutex
	waiting map[int64]chan Response
	closed  bool

	events chan jobs.Event

	readErr error
	done    chan struct{}
}

// Dial connects to the daemon.
func Dial(path string) (*Client, error) {
	if path == "" {
		path = SocketPath
	}
	conn, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		var opErr *net.OpError
		if errors.As(err, &opErr) {
			return nil, fmt.Errorf("%w: %s", ErrNoDaemon, path)
		}
		return nil, err
	}

	c := &Client{
		conn:    conn,
		enc:     json.NewEncoder(conn),
		waiting: map[int64]chan Response{},
		// Buffered so a caller that is slow to read events does not stall the
		// reader goroutine and with it every pending response.
		events: make(chan jobs.Event, 512),
		done:   make(chan struct{}),
	}
	go c.read()
	return c, nil
}

// Events is the stream of job events, live after jobs.subscribe. It is closed
// when the connection ends.
func (c *Client) Events() <-chan jobs.Event { return c.events }

// Close ends the connection.
func (c *Client) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()
	return c.conn.Close()
}

// Done is closed when the reader stops, whether by Close or by the daemon
// going away.
func (c *Client) Done() <-chan struct{} { return c.done }

// Err reports why the connection ended.
func (c *Client) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.readErr
}

func (c *Client) read() {
	defer close(c.done)
	defer close(c.events)

	sc := bufio.NewScanner(c.conn)
	sc.Buffer(make([]byte, 0, 64*1024), 4<<20)

	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}

		/* Responses and events share the socket. A response always carries a
		 * non-zero id and an event never does, so one probe distinguishes them
		 * without decoding twice. */
		var probe struct {
			ID    int64  `json:"id"`
			Event string `json:"event"`
		}
		if err := json.Unmarshal(line, &probe); err != nil {
			continue
		}

		if probe.Event != "" {
			var e jobs.Event
			if json.Unmarshal(line, &e) == nil {
				select {
				case c.events <- e:
				default:
					// The caller is not keeping up. Dropping is right: the
					// daemon has already dropped for the same reason, and
					// blocking here would stall responses too.
				}
			}
			continue
		}

		var resp Response
		if json.Unmarshal(line, &resp) != nil {
			continue
		}
		c.mu.Lock()
		ch, ok := c.waiting[resp.ID]
		delete(c.waiting, resp.ID)
		c.mu.Unlock()
		if ok {
			ch <- resp
		}
	}

	err := sc.Err()
	c.mu.Lock()
	c.readErr = err
	waiting := c.waiting
	c.waiting = map[int64]chan Response{}
	c.mu.Unlock()

	// Nobody is going to answer these now.
	for _, ch := range waiting {
		ch <- Response{Error: Errf(CodeUnavailable, "connection closed")}
	}
}

// Call makes one request and decodes the result into out, which may be nil.
func (c *Client) Call(method string, params, out any) error {
	var raw json.RawMessage
	if params != nil {
		b, err := json.Marshal(params)
		if err != nil {
			return fmt.Errorf("ipc: encode params: %w", err)
		}
		raw = b
	}

	id := c.nextID.Add(1)
	ch := make(chan Response, 1)

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return ErrNoDaemon
	}
	c.waiting[id] = ch
	err := c.enc.Encode(Request{ID: id, Method: method, Params: raw})
	c.mu.Unlock()

	if err != nil {
		c.mu.Lock()
		delete(c.waiting, id)
		c.mu.Unlock()
		return fmt.Errorf("ipc: send %s: %w", method, err)
	}

	resp := <-ch
	if resp.Error != nil {
		return resp.Error
	}
	if out == nil {
		return nil
	}
	b, err := json.Marshal(resp.Result)
	if err != nil {
		return fmt.Errorf("ipc: re-encode result: %w", err)
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("ipc: decode result of %s: %w", method, err)
	}
	return nil
}

// Subscribe asks for the event stream. Events then arrive on Events().
func (c *Client) Subscribe(p SubscribeParams) (jobs.Snapshot, error) {
	var snap jobs.Snapshot
	err := c.Call(MethodJobsSubscribe, p, &snap)
	return snap, err
}

// dialRaw opens the socket without the demultiplexing reader, for tests that
// need to speak the wire format directly.
func dialRaw(path string) (net.Conn, error) {
	return net.DialTimeout("unix", path, 5*time.Second)
}
