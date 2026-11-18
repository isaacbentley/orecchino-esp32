// SPDX-License-Identifier: GPL-3.0-or-later
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	droneguideWFSEndpoint = "https://map.droneguide.be/ows"
	droneguideWFSPageSize = 2000
	droneguideWFSMaxPages = 12
	droneguideWFSWindow   = 24 * time.Hour
)

type droneguideWFSPage struct {
	droneguideCollection
	NumberMatched  json.RawMessage
	NumberReturned *int
	TotalFeatures  json.RawMessage
}

func droneguideWFSURL(endpoint string, now time.Time) (*url.URL, error) {
	address, err := url.Parse(endpoint)
	if err != nil || address.Host == "" {
		return nil, errors.New("ongeldige Droneguide-bron")
	}
	windowTime := func(t time.Time) string {
		return strings.ReplaceAll(t.UTC().Format("2006-01-02T15:04:05.000Z"), ":", `\:`)
	}
	query := address.Query()
	query.Set("service", "WFS")
	query.Set("version", "2.0.0")
	query.Set("request", "GetFeature")
	query.Set("typeNames", "uaszone")
	query.Set("srsName", "EPSG:4326")
	query.Set("outputFormat", "application/json")
	query.Set("cql_filter", "type_code <> 'TIME_ZONE'")
	query.Set("viewParams", "window_start:"+windowTime(now)+";window_end:"+windowTime(now.Add(droneguideWFSWindow))+";show_planned:true")
	query.Set("count", strconv.Itoa(droneguideWFSPageSize))
	query.Set("sortBy", "unique_identifier A")
	address.RawQuery = query.Encode()
	return address, nil
}

func (page droneguideWFSPage) resultCount() (int, error) {
	total := -1
	for _, value := range []json.RawMessage{page.NumberMatched, page.TotalFeatures} {
		var count int
		if len(value) == 0 || bytes.Equal(value, []byte("null")) || json.Unmarshal(value, &count) != nil {
			continue
		}
		if total >= 0 && count != total {
			return 0, errors.New("Droneguide meldt tegenstrijdige resultaataantallen")
		}
		total = count
	}
	if total <= 0 || total > droneguideMaxFeatures {
		return 0, errors.New("het totale aantal online Droneguide-zones kan niet worden bevestigd")
	}
	return total, nil
}

func fetchDroneguideWFS(ctx context.Context, client *http.Client, endpoint string, start time.Time) ([]byte, []droneguideZone, int, error) {
	address, err := droneguideWFSURL(endpoint, start)
	if err != nil {
		return nil, nil, 0, err
	}
	features := make([]json.RawMessage, 0)
	total, remainingBytes := -1, droneguideMaxJSON
	var collection droneguideCollection
	for pageIndex := 0; pageIndex < droneguideWFSMaxPages; pageIndex++ {
		query := address.Query()
		query.Set("startIndex", strconv.Itoa(len(features)))
		address.RawQuery = query.Encode()
		page, count, err := readDroneguideWFSPage(ctx, client, address.String(), remainingBytes)
		if err != nil {
			return nil, nil, 0, err
		}
		remainingBytes -= count
		if page.Type != "FeatureCollection" {
			return nil, nil, 0, errors.New("Droneguide levert geen WFS-zones")
		}
		if err := page.checkGeoJSON(); err != nil {
			return nil, nil, 0, err
		}
		expected, err := page.resultCount()
		if err != nil {
			return nil, nil, 0, err
		}
		if total == -1 {
			total = expected
			collection = page.droneguideCollection
		}
		if total != expected {
			return nil, nil, 0, errors.New("de Droneguide-zoneverzameling veranderde tijdens het ophalen")
		}
		var items []json.RawMessage
		if err := json.Unmarshal(page.Features, &items); err != nil || len(items) == 0 ||
			page.NumberReturned == nil || len(items) != *page.NumberReturned ||
			len(features)+len(items) > total {
			return nil, nil, 0, errors.New("Droneguide levert een onvolledige resultaatpagina")
		}
		features = append(features, items...)
		if len(features) == total {
			break
		}
	}
	if len(features) != total {
		return nil, nil, 0, errors.New("de online Droneguide-zoneverzameling is onvolledig")
	}
	collection.Features, err = json.Marshal(features)
	if err != nil {
		return nil, nil, 0, err
	}
	raw, err := json.Marshal(collection)
	if err != nil {
		return nil, nil, 0, err
	}
	if len(raw) > droneguideMaxJSON {
		return nil, nil, 0, errors.New("de online Droneguide-zones overschrijden de groottebeperking")
	}
	zones, omitted, err := parseDroneguideSnapshot(raw, true)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("online Droneguide-zones lezen mislukt. %w", err)
	}
	return raw, zones, omitted, nil
}

func readDroneguideWFSPage(ctx context.Context, client *http.Client, address string, limit int) (droneguideWFSPage, int, error) {
	var page droneguideWFSPage
	if limit <= 0 {
		return page, 0, errors.New("de online Droneguide-zones overschrijden de groottebeperking")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return page, 0, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "Orecchino Windows (Droneguide WFS)")
	response, err := client.Do(request)
	if err != nil {
		return page, 0, errors.New("Droneguide kan niet worden bereikt")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return page, 0, fmt.Errorf("Droneguide antwoordt met HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		return page, 0, errors.New("de online Droneguide-zones kunnen niet worden gelezen")
	}
	if len(raw) > limit {
		return page, 0, errors.New("de online Droneguide-zones overschrijden de groottebeperking")
	}
	if err := json.Unmarshal(raw, &page); err != nil {
		return page, 0, errors.New("Droneguide levert geen leesbare WFS-JSON")
	}
	return page, len(raw), nil
}
