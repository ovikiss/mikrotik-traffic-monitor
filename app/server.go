package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var (
	settingsPath          = os.Getenv("SETTINGS_PATH_ENV")
	wwwDir                = os.Getenv("WWW_DIR")
	staticDir             = os.Getenv("STATIC_DIR_ENV")
	effectivePollInterval = os.Getenv("EFFECTIVE_POLL_INTERVAL_ENV")
	port                  = os.Getenv("HTTP_PORT_ENV")
)

type Settings struct {
	PollInterval string `json:"poll_interval,omitempty"`
	Theme        string `json:"theme,omitempty"`
	Language     string `json:"language,omitempty"`
	FontSize     string `json:"font_size,omitempty"`
}

func readSettings() (Settings, error) {
	var s Settings
	data, err := os.ReadFile(settingsPath)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return s, err
	}
	err = json.Unmarshal(data, &s)
	return s, err
}

func writeSettings(s Settings) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := settingsPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmp, settingsPath)
}

func normalizeInterval(v string) string {
	v = strings.ToLower(strings.TrimSpace(v))
	switch v {
	case "60m":
		return "1h"
	case "180m":
		return "3h"
	case "360m":
		return "6h"
	case "720m":
		return "12h"
	}
	if n, err := strconv.Atoi(v); err == nil {
		switch n {
		case 60:
			return "1h"
		case 180:
			return "3h"
		case 360:
			return "6h"
		case 720:
			return "12h"
		}
	}
	return v
}

func validInterval(v string) bool {
	return v == "1h" || v == "3h" || v == "6h" || v == "12h"
}

func validTheme(v string) bool {
	return v == "light" || v == "dark" || v == "auto"
}

func validFontSize(v string) bool {
	return v == "25" || v == "50" || v == "100"
}

var langRegex = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9-_]{1,15}$`)

func validLanguage(v string) bool {
	return langRegex.MatchString(v)
}

func main() {
	if settingsPath == "" {
		settingsPath = "/data/settings.json"
	}
	if wwwDir == "" {
		wwwDir = "/data/www"
	}
	if staticDir == "" {
		staticDir = "/app"
	}
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// Route settings API GET
		if path == "/api/settings.json" {
			if r.Method != http.MethodGet {
				http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
				return
			}
			cfg, err := readSettings()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			resp := map[string]string{
				"poll_interval":           cfg.PollInterval,
				"effective_poll_interval": effectivePollInterval,
				"theme":                   cfg.Theme,
				"language":                cfg.Language,
				"font_size":               cfg.FontSize,
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Cache-Control", "no-store")
			json.NewEncoder(w).Encode(resp)
			return
		}

		// Route settings API POST
		if path == "/api/settings" {
			if r.Method != http.MethodPost {
				http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
				return
			}
			var req map[string]interface{}
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "invalid_json"})
				return
			}

			cfg, err := readSettings()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}

			changed := false
			out := map[string]interface{}{"ok": true}

			if val, ok := req["poll_interval"]; ok {
				if str, ok := val.(string); ok {
					interval := normalizeInterval(str)
					if !validInterval(interval) {
						w.Header().Set("Content-Type", "application/json")
						w.WriteHeader(http.StatusBadRequest)
						json.NewEncoder(w).Encode(map[string]string{"error": "invalid_interval"})
						return
					}
					cfg.PollInterval = interval
					out["poll_interval"] = interval
					changed = true
				}
			}

			if val, ok := req["theme"]; ok {
				if str, ok := val.(string); ok {
					theme := strings.ToLower(strings.TrimSpace(str))
					if !validTheme(theme) {
						w.Header().Set("Content-Type", "application/json")
						w.WriteHeader(http.StatusBadRequest)
						json.NewEncoder(w).Encode(map[string]string{"error": "invalid_theme"})
						return
					}
					cfg.Theme = theme
					out["theme"] = theme
					changed = true
				}
			}

			if val, ok := req["language"]; ok {
				if str, ok := val.(string); ok {
					lang := strings.ToLower(strings.TrimSpace(str))
					if !validLanguage(lang) {
						w.Header().Set("Content-Type", "application/json")
						w.WriteHeader(http.StatusBadRequest)
						json.NewEncoder(w).Encode(map[string]string{"error": "invalid_language"})
						return
					}
					cfg.Language = lang
					out["language"] = lang
					changed = true
				}
			}

			if val, ok := req["font_size"]; ok {
				if str, ok := val.(string); ok {
					size := strings.TrimSpace(str)
					if !validFontSize(size) {
						w.Header().Set("Content-Type", "application/json")
						w.WriteHeader(http.StatusBadRequest)
						json.NewEncoder(w).Encode(map[string]string{"error": "invalid_font_size"})
						return
					}
					cfg.FontSize = size
					out["font_size"] = size
					changed = true
				}
			}

			if !changed {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadRequest)
				json.NewEncoder(w).Encode(map[string]string{"error": "empty_payload"})
				return
			}

			if err := writeSettings(cfg); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}

			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(out)
			return
		}

		// Resolve static file paths
		var filepathStr string
		var cacheStatic bool

		if path == "" || path == "/" || path == "/index.html" {
			filepathStr = filepath.Join(staticDir, "www/index.html")
			cacheStatic = true
		} else if strings.HasPrefix(path, "/www/") {
			filepathStr = filepath.Join(staticDir, path)
			cacheStatic = true
		} else if path == "/branding.json" {
			filepathStr = filepath.Join(staticDir, "branding.json")
			cacheStatic = true
		} else if path == "/header-controls.json" {
			filepathStr = filepath.Join(staticDir, "www/header-controls.json")
			cacheStatic = true
		} else if strings.HasPrefix(path, "/styles-") || strings.HasPrefix(path, "/images/") || strings.HasPrefix(path, "/common/") {
			filepathStr = filepath.Join(staticDir, "www", strings.TrimPrefix(path, "/"))
			cacheStatic = true
		} else if strings.HasPrefix(path, "/i18n/") {
			filepathStr = filepath.Join(staticDir, strings.TrimPrefix(path, "/"))
			cacheStatic = true
		} else if strings.HasPrefix(path, "/api/") || path == "/day.csv" || path == "/month.csv" || path == "/year.csv" || path == "/daily.csv" || path == "/month_days.csv" || path == "/year_months.csv" || path == "/info.txt" {
			filepathStr = filepath.Join(wwwDir, path)
			cacheStatic = false
		} else {
			http.Error(w, "File not found", http.StatusNotFound)
			return
		}

		// Security check: ensure path doesn't escape allowed root directories
		filepathStr = filepath.Clean(filepathStr)
		if strings.HasPrefix(filepathStr, staticDir) || strings.HasPrefix(filepathStr, wwwDir) {
			serveFile(w, filepathStr, cacheStatic)
		} else {
			http.Error(w, "Access denied", http.StatusForbidden)
		}
	})

	log.Printf("Starting server on port %s...", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}

func serveFile(w http.ResponseWriter, path string, cacheStatic bool) {
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil || stat.IsDir() {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	if cacheStatic {
		w.Header().Set("Cache-Control", "public, max-age=3600")
	} else {
		w.Header().Set("Cache-Control", "no-store")
	}

	// Guess Content-Type
	contentType := "text/plain; charset=utf-8"
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".html":
		contentType = "text/html; charset=utf-8"
	case ".css":
		contentType = "text/css; charset=utf-8"
	case ".js":
		contentType = "application/javascript; charset=utf-8"
	case ".json":
		contentType = "application/json; charset=utf-8"
	case ".png":
		contentType = "image/png"
	case ".svg":
		contentType = "image/svg+xml"
	case ".csv":
		contentType = "text/csv; charset=utf-8"
	case ".yaml", ".yml":
		contentType = "application/x-yaml; charset=utf-8"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", strconv.FormatInt(stat.Size(), 10))

	io.Copy(w, f)
}
