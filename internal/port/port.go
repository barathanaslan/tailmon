// Package port holds the agent's TCP port. Its own package so both agent
// (server) and aggregate (client) can use it without an import cycle.
package port

// Default: 7020 (7012/7013/8765 are taken by other services here).
const Default = 7020
