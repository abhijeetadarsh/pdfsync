package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// Record is the unit of sync. Annotations are stored as independent records
// (not baked into the PDF bytes), so editing one highlight costs a few hundred
// bytes on the wire instead of re-uploading the whole file.
type Record struct {
	Kind    string          `json:"kind"`
	ID      string          `json:"id"`
	DocID   string          `json:"docId,omitempty"`
	HLC     string          `json:"hlc"`
	Deleted bool            `json:"deleted,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
	Seq     int64           `json:"seq,omitempty"`
}

type SyncRequest struct {
	Cursor  int64    `json:"cursor"`
	Changes []Record `json:"changes"`
	Limit   int      `json:"limit"`
}

type Rejection struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	Reason string `json:"reason"`
}

type SyncResponse struct {
	Accepted   []string    `json:"accepted"` // "kind/id" of changes that won
	Rejected   []Rejection `json:"rejected"`
	Changes    []Record    `json:"changes"`
	Cursor     int64       `json:"cursor"`
	HasMore    bool        `json:"hasMore"`
	ServerTime int64       `json:"serverTime"` // ms; lets clients correct HLC clock skew
}

// HLC format: <13-digit unix ms>-<4 hex counter>-<node id>
// Fixed width => lexicographic order == causal/temporal order.
var hlcRe = regexp.MustCompile(`^(\d{13})-([0-9a-f]{4})-([A-Za-z0-9_]{1,32})$`)

var allowedKinds = map[string]bool{
	"document":   true, // {title, sha256, size, pageCount}
	"annotation": true, // {page, type, color, rects|strokes|pos, text}
	"readstate":  true, // {page, zoom} – last position, per document
	"folder":     true, // {name, parentId}
}

const (
	maxClockSkew  = 10 * time.Minute
	maxDataBytes  = 256 << 10
	maxChangesReq = 2000
	defaultLimit  = 500
	maxLimit      = 2000
)

func validate(r *Record, now time.Time) error {
	if !allowedKinds[r.Kind] {
		return fmt.Errorf("unknown kind %q", r.Kind)
	}
	if r.ID == "" || len(r.ID) > 64 {
		return errors.New("bad id")
	}
	m := hlcRe.FindStringSubmatch(r.HLC)
	if m == nil {
		return errors.New("bad hlc")
	}
	ms, _ := strconv.ParseInt(m[1], 10, 64)
	if time.UnixMilli(ms).After(now.Add(maxClockSkew)) {
		// A client with a wildly fast clock would otherwise win every conflict forever.
		return errors.New("hlc too far in the future")
	}
	if len(r.Data) > maxDataBytes {
		return errors.New("data too large")
	}
	if len(r.Data) == 0 {
		r.Data = json.RawMessage("{}")
	}
	if !json.Valid(r.Data) {
		return errors.New("data is not valid json")
	}
	if r.Kind == "annotation" || r.Kind == "readstate" {
		if r.DocID == "" {
			return errors.New("docId required")
		}
	}
	return nil
}

// Sync applies the client's pending changes (last-writer-wins per record,
// ordered by HLC) and returns everything that changed since the client's cursor.
// It is one atomic transaction: either all accepted changes commit or none do.
func (s *Store) Sync(userID string, req SyncRequest) (*SyncResponse, bool, error) {
	if len(req.Changes) > maxChangesReq {
		return nil, false, fmt.Errorf("too many changes (max %d)", maxChangesReq)
	}
	limit := req.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	now := time.Now()
	resp := &SyncResponse{Accepted: []string{}, Rejected: []Rejection{}, Changes: []Record{}, ServerTime: now.UnixMilli()}

	tx, err := s.db.Begin()
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback()

	var seq int64
	if err := tx.QueryRow(`SELECT seq FROM users WHERE id=?`, userID).Scan(&seq); err != nil {
		return nil, false, err
	}
	startSeq := seq
	// Writes from *this* request; we skip echoing them back to the sender.
	echo := map[string]string{}

	for i := range req.Changes {
		c := &req.Changes[i]
		key := c.Kind + "/" + c.ID
		if err := validate(c, now); err != nil {
			resp.Rejected = append(resp.Rejected, Rejection{c.Kind, c.ID, err.Error()})
			continue
		}
		if c.Kind == "document" && !c.Deleted {
			var d struct {
				SHA256 string `json:"sha256"`
			}
			_ = json.Unmarshal(c.Data, &d)
			if !shaRe.MatchString(d.SHA256) {
				resp.Rejected = append(resp.Rejected, Rejection{c.Kind, c.ID, "document needs data.sha256"})
				continue
			}
			var owned int
			if err := tx.QueryRow(`SELECT COUNT(*) FROM user_blobs WHERE user_id=? AND sha256=?`,
				userID, d.SHA256).Scan(&owned); err != nil {
				return nil, false, err
			}
			if owned == 0 {
				resp.Rejected = append(resp.Rejected, Rejection{c.Kind, c.ID, "blob not uploaded"})
				continue
			}
		}

		var curHLC string
		err := tx.QueryRow(`SELECT hlc FROM records WHERE user_id=? AND kind=? AND id=?`,
			userID, c.Kind, c.ID).Scan(&curHLC)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, false, err
		}
		if err == nil && curHLC >= c.HLC {
			// Stale write: the stored version is newer. Not an error – the client
			// will receive the winning version in the pull half of this response
			// (or already has it).
			continue
		}
		seq++
		deleted := 0
		data := string(c.Data)
		if c.Deleted {
			deleted = 1
			data = "{}" // tombstones carry no payload
		}
		if _, err := tx.Exec(`INSERT INTO records(user_id,kind,id,doc_id,hlc,deleted,data,seq)
			VALUES(?,?,?,?,?,?,?,?)
			ON CONFLICT(user_id,kind,id) DO UPDATE SET
				doc_id=excluded.doc_id, hlc=excluded.hlc, deleted=excluded.deleted,
				data=excluded.data, seq=excluded.seq`,
			userID, c.Kind, c.ID, c.DocID, c.HLC, deleted, data, seq); err != nil {
			return nil, false, err
		}
		resp.Accepted = append(resp.Accepted, key)
		echo[key] = c.HLC
	}
	if seq != startSeq {
		if _, err := tx.Exec(`UPDATE users SET seq=? WHERE id=?`, seq, userID); err != nil {
			return nil, false, err
		}
	}

	// Pull: changes after the client's cursor, oldest first, paginated.
	rows, err := tx.Query(`SELECT kind,id,doc_id,hlc,deleted,data,seq FROM records
		WHERE user_id=? AND seq>? ORDER BY seq LIMIT ?`, userID, req.Cursor, limit+1)
	if err != nil {
		return nil, false, err
	}
	cursor := req.Cursor
	n := 0
	for rows.Next() {
		var r Record
		var deleted int
		var data string
		if err := rows.Scan(&r.Kind, &r.ID, &r.DocID, &r.HLC, &deleted, &data, &r.Seq); err != nil {
			rows.Close()
			return nil, false, err
		}
		n++
		if n > limit {
			resp.HasMore = true
			break
		}
		cursor = r.Seq
		if h, ok := echo[r.Kind+"/"+r.ID]; ok && h == r.HLC {
			continue // client already has exactly this version
		}
		r.Deleted = deleted == 1
		if !r.Deleted {
			r.Data = json.RawMessage(data)
		}
		resp.Changes = append(resp.Changes, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	resp.Cursor = cursor
	if err := tx.Commit(); err != nil {
		return nil, false, err
	}
	return resp, seq != startSeq, nil
}

func (s *Store) CurrentSeq(userID string) (int64, error) {
	var seq int64
	err := s.db.QueryRow(`SELECT seq FROM users WHERE id=?`, userID).Scan(&seq)
	return seq, err
}
