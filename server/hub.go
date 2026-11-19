package main

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Hub fans out tiny "poke" messages to every connected device of a user when
// their data changes. Devices then run a normal delta sync. Keeping the socket
// as a doorbell (not a data channel) means one code path for sync, and a
// missed poke is harmless: the next periodic/foreground sync catches up.
type Hub struct {
	mu    sync.Mutex
	conns map[string]map[*client]struct{}
}

type client struct {
	deviceID string
	send     chan []byte
}

func NewHub() *Hub { return &Hub{conns: map[string]map[*client]struct{}{}} }

func (h *Hub) add(userID string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[userID] == nil {
		h.conns[userID] = map[*client]struct{}{}
	}
	h.conns[userID][c] = struct{}{}
}

func (h *Hub) remove(userID string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns[userID], c)
	if len(h.conns[userID]) == 0 {
		delete(h.conns, userID)
	}
}

// Poke notifies all of a user's devices except the originator.
func (h *Hub) Poke(userID, fromDevice string, cursor int64) {
	msg, _ := json.Marshal(map[string]any{"type": "changed", "cursor": cursor})
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.conns[userID] {
		if fromDevice != "" && c.deviceID == fromDevice {
			continue
		}
		select {
		case c.send <- msg:
		default: // slow client; it will catch up on its next sync
		}
	}
}

func (h *Hub) Serve(ctx context.Context, conn *websocket.Conn, userID, deviceID string, cursor int64) {
	c := &client{deviceID: deviceID, send: make(chan []byte, 8)}
	h.add(userID, c)
	defer h.remove(userID, c)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// Reader: we don't expect messages, but must read to process pings/close.
	go func() {
		defer cancel()
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	// Tell the client where the server is right now, so it can sync immediately
	// if it fell behind while disconnected.
	hello, _ := json.Marshal(map[string]any{"type": "hello", "cursor": cursor})
	if err := conn.Write(ctx, websocket.MessageText, hello); err != nil {
		return
	}
	ping := time.NewTicker(30 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			conn.Close(websocket.StatusNormalClosure, "")
			return
		case msg := <-c.send:
			wctx, wc := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Write(wctx, websocket.MessageText, msg)
			wc()
			if err != nil {
				return
			}
		case <-ping.C:
			pctx, pc := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Ping(pctx)
			pc()
			if err != nil {
				return
			}
		}
	}
}
