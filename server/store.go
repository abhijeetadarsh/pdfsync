package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite"
)

// Store wraps the SQLite metadata database.
//
// Data model: every synced object (document, annotation, reading state, ...) is
// a generic "record" keyed by (user, kind, id). Each accepted write bumps a
// per-user monotonically increasing sequence number, so a client can ask for
// "everything that changed after seq N" – an O(changes) delta, never a full
// re-download.
type Store struct {
	db *sql.DB
}

const schema = `
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS users (
	id         TEXT PRIMARY KEY,
	email      TEXT NOT NULL UNIQUE,
	pw_hash    BLOB NOT NULL,
	seq        INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
	token_hash TEXT PRIMARY KEY,
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blobs (
	sha256     TEXT PRIMARY KEY,
	size       INTEGER NOT NULL,
	created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS user_blobs (
	user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	sha256  TEXT NOT NULL REFERENCES blobs(sha256),
	PRIMARY KEY (user_id, sha256)
);
CREATE TABLE IF NOT EXISTS records (
	user_id TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	kind    TEXT    NOT NULL,
	id      TEXT    NOT NULL,
	doc_id  TEXT    NOT NULL DEFAULT '',
	hlc     TEXT    NOT NULL,
	deleted INTEGER NOT NULL DEFAULT 0,
	data    TEXT    NOT NULL DEFAULT '{}',
	seq     INTEGER NOT NULL,
	PRIMARY KEY (user_id, kind, id)
);
CREATE INDEX IF NOT EXISTS records_by_seq ON records(user_id, seq);
`

func OpenStore(path string) (*Store, error) {
	// _txlock=immediate: writers take the lock up front, avoiding SQLITE_BUSY upgrades.
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_txlock=immediate")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // SQLite: single writer; keeps sequence allocation trivially serial.
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func hashToken(t string) string {
	h := sha256.Sum256([]byte(t))
	return hex.EncodeToString(h[:])
}

var (
	ErrEmailTaken   = errors.New("email already registered")
	ErrBadLogin     = errors.New("invalid email or password")
	ErrUnauthorized = errors.New("unauthorized")
)

func (s *Store) Register(email, password string) (userID, token string, err error) {
	email = strings.ToLower(strings.TrimSpace(email))
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", "", err
	}
	userID = randomHex(16)
	_, err = s.db.Exec(`INSERT INTO users(id,email,pw_hash,created_at) VALUES(?,?,?,?)`,
		userID, email, hash, time.Now().Unix())
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return "", "", ErrEmailTaken
		}
		return "", "", err
	}
	token, err = s.issueToken(userID)
	return userID, token, err
}

func (s *Store) Login(email, password string) (userID, token string, err error) {
	email = strings.ToLower(strings.TrimSpace(email))
	var hash []byte
	err = s.db.QueryRow(`SELECT id, pw_hash FROM users WHERE email=?`, email).Scan(&userID, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrBadLogin
	} else if err != nil {
		return "", "", err
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(password)) != nil {
		return "", "", ErrBadLogin
	}
	token, err = s.issueToken(userID)
	return userID, token, err
}

func (s *Store) issueToken(userID string) (string, error) {
	tok := randomHex(32)
	_, err := s.db.Exec(`INSERT INTO tokens(token_hash,user_id,created_at) VALUES(?,?,?)`,
		hashToken(tok), userID, time.Now().Unix())
	return tok, err
}

func (s *Store) Logout(token string) error {
	_, err := s.db.Exec(`DELETE FROM tokens WHERE token_hash=?`, hashToken(token))
	return err
}

func (s *Store) UserForToken(token string) (string, error) {
	var uid string
	err := s.db.QueryRow(`SELECT user_id FROM tokens WHERE token_hash=?`, hashToken(token)).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrUnauthorized
	}
	return uid, err
}

// ---- blobs ----

func (s *Store) UserHasBlob(userID, sha string) (bool, int64, error) {
	var size int64
	err := s.db.QueryRow(`SELECT b.size FROM user_blobs ub JOIN blobs b ON b.sha256=ub.sha256
		WHERE ub.user_id=? AND ub.sha256=?`, userID, sha).Scan(&size)
	if errors.Is(err, sql.ErrNoRows) {
		return false, 0, nil
	}
	return err == nil, size, err
}

func (s *Store) BlobExists(sha string) (bool, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM blobs WHERE sha256=?`, sha).Scan(&n)
	return n > 0, err
}

func (s *Store) LinkBlob(userID, sha string, size int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT OR IGNORE INTO blobs(sha256,size,created_at) VALUES(?,?,?)`,
		sha, size, time.Now().Unix()); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT OR IGNORE INTO user_blobs(user_id,sha256) VALUES(?,?)`, userID, sha); err != nil {
		return err
	}
	return tx.Commit()
}

// UnreferencedBlobs returns blobs no live document of any user points to and
// unlinks them, so the caller can delete the files.
func (s *Store) CollectGarbageBlobs(olderThan time.Duration) ([]string, error) {
	cutoff := time.Now().Add(-olderThan).Unix()
	rows, err := s.db.Query(`SELECT sha256 FROM blobs WHERE created_at < ? AND sha256 NOT IN (
		SELECT json_extract(data,'$.sha256') FROM records
		WHERE kind='document' AND deleted=0 AND json_extract(data,'$.sha256') IS NOT NULL)`, cutoff)
	if err != nil {
		return nil, err
	}
	var shas []string
	for rows.Next() {
		var sha string
		if err := rows.Scan(&sha); err != nil {
			rows.Close()
			return nil, err
		}
		shas = append(shas, sha)
	}
	rows.Close()
	for _, sha := range shas {
		if _, err := s.db.Exec(`DELETE FROM user_blobs WHERE sha256=?`, sha); err != nil {
			return nil, err
		}
		if _, err := s.db.Exec(`DELETE FROM blobs WHERE sha256=?`, sha); err != nil {
			return nil, err
		}
	}
	return shas, nil
}
