package engines

import (
	"fmt"
	"sort"
	"sync"
)

// DefaultID is the engine every installation predating engines is using. A
// config with no "engine" key resolves to this rather than erroring, which is
// what makes the change invisible on upgrade.
const DefaultID = "timeshift"

var (
	mu       sync.RWMutex
	registry = map[string]Engine{}
)

// Register adds an engine. Engine packages call this from init(), and
// cmd/timeshiftd imports them for the side effect -- so which engines exist is
// decided by the import list of one file, not by a build tag or a plugin
// search path.
//
// Panics on a duplicate id: two engines answering to one name is a programming
// error that would otherwise resolve differently depending on link order.
func Register(e Engine) {
	mu.Lock()
	defer mu.Unlock()
	id := e.ID()
	if _, dup := registry[id]; dup {
		panic("engines: duplicate registration for " + id)
	}
	registry[id] = e
}

// Lookup returns the engine with the given id. An empty id means DefaultID.
func Lookup(id string) (Engine, error) {
	if id == "" {
		id = DefaultID
	}
	mu.RLock()
	defer mu.RUnlock()
	e, ok := registry[id]
	if !ok {
		return nil, fmt.Errorf("engines: no engine named %q (have %v)", id, idsLocked())
	}
	return e, nil
}

// List returns every registered engine, ordered by id so output is stable.
func List() []Engine {
	mu.RLock()
	defer mu.RUnlock()
	out := make([]Engine, 0, len(registry))
	for _, id := range idsLocked() {
		out = append(out, registry[id])
	}
	return out
}

// IDs returns the registered engine ids, sorted.
func IDs() []string {
	mu.RLock()
	defer mu.RUnlock()
	return idsLocked()
}

func idsLocked() []string {
	out := make([]string, 0, len(registry))
	for id := range registry {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}
