package main

import (
	"encoding/json"

	"github.com/makeafide/timeshift/src-go/internal/ipc"
)

/* decode reads a handler's params, or refuses the request.
 *
 * Seventeen handlers used to write
 *
 *     var in ipc.SomeParams
 *     json.Unmarshal(params, &in)
 *
 * and carry on with whatever came back. JSON that fails to parse leaves the
 * zero value, so the request was not refused -- it was answered, about
 * something else. Two of those mattered:
 *
 *   - repo.select: a malformed body left DryRun false, so a request the client
 *     meant as a rehearsal WROTE the configuration.
 *   - snapshot.create: a malformed body left AttachExisting false, so two apt
 *     frontends racing took two snapshots instead of watching one.
 *
 * The rest degraded to an empty struct and were mostly caught by a later
 * emptiness check, which is luck rather than design.
 *
 * Empty params are not an error: thirteen methods take none, and a client that
 * sends nothing for those is correct.
 */
func decode[T any](params json.RawMessage) (T, error) {
	var in T
	if len(params) == 0 {
		return in, nil
	}
	if err := json.Unmarshal(params, &in); err != nil {
		return in, ipc.Errf(ipc.CodeBadRequest, "malformed parameters: %v", err)
	}
	return in, nil
}
