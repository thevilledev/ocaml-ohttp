// A differential-testing peer over chris-wood/ohttp-go.
//
// The driver in ../differential.ml starts this program and exchanges one JSON
// object per line with it: a request on standard input, its answer on standard
// output, strictly in turn. Every byte string is lowercase hexadecimal, since
// HTTP field values and ciphertexts are not valid UTF-8.
//
//	request:  {"id": 1, "op": "hello"}
//	answer:   {"id": 1, "ok": true, ...}
//	          {"id": 1, "ok": false, "error": {"kind": K, "message": "..."}}
//
// An error kind says what the driver should make of it:
//
//	unsupported  this implementation lacks the operation, suite, or feature;
//	             the case is skipped
//	rejected     the library refused the input; an answer like any other, to
//	             be compared with the driver's own verdict
//	internal     the harness is at fault, or the library panicked
//
// The operations are those of ../README.md. Handles name contexts that live
// between two operations, and are consumed by the second.
package main

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"

	ohttp "github.com/chris-wood/ohttp-go"
	"github.com/cloudflare/circl/hpke"
)

const moduleVersion = "v0.0.0-20260205154755-776f22a178b8"

type request struct {
	ID          int             `json:"id"`
	Op          string          `json:"op"`
	KeyID       int             `json:"key_id"`
	KEM         int             `json:"kem"`
	Symmetric   [][2]int        `json:"symmetric"`
	Seed        string          `json:"seed"`
	Config      string          `json:"config"`
	ConfigList  *string         `json:"config_list"`
	Request     string          `json:"request"`
	Response    string          `json:"response"`
	EncRequest  string          `json:"enc_request"`
	EncResponse string          `json:"enc_response"`
	Handle      int             `json:"handle"`
	Message     string          `json:"message"`
	Decoded     json.RawMessage `json:"decoded"`
	Framing     string          `json:"framing"`
}

type peerError struct {
	kind    string
	message string
}

func (e peerError) Error() string { return e.message }

func unsupported(format string, args ...any) error {
	return peerError{"unsupported", fmt.Sprintf(format, args...)}
}

func rejected(err error) error { return peerError{"rejected", err.Error()} }

func internal(format string, args ...any) error {
	return peerError{"internal", fmt.Sprintf(format, args...)}
}

func unhex(s string) ([]byte, error) {
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, internal("invalid hexadecimal: %v", err)
	}
	return b, nil
}

var (
	nextHandle      = 1
	clientContexts  = map[int]ohttp.EncapsulatedRequestContext{}
	gatewayContexts = map[int]ohttp.DecapsulateRequestContext{}
)

// ohttp-go gives a key one KDF and AEAD pair.
func privateConfig(r request) (ohttp.PrivateConfig, error) {
	if len(r.Symmetric) != 1 {
		return ohttp.PrivateConfig{}, unsupported("a key configuration has exactly one symmetric pair")
	}
	kem, kdf, aead := hpke.KEM(r.KEM), hpke.KDF(r.Symmetric[0][0]), hpke.AEAD(r.Symmetric[0][1])
	if !kem.IsValid() || !kdf.IsValid() || !aead.IsValid() {
		return ohttp.PrivateConfig{}, unsupported("unknown algorithm")
	}
	seed, err := unhex(r.Seed)
	if err != nil {
		return ohttp.PrivateConfig{}, err
	}
	config, err := ohttp.NewConfigFromSeed(uint8(r.KeyID), kem, kdf, aead, seed)
	if err != nil {
		return ohttp.PrivateConfig{}, rejected(err)
	}
	return config, nil
}

type field [2]string

type message struct {
	Kind          string          `json:"kind"`
	Method        string          `json:"method,omitempty"`
	Scheme        string          `json:"scheme,omitempty"`
	Authority     string          `json:"authority,omitempty"`
	Path          string          `json:"path,omitempty"`
	Informational []informational `json:"informational,omitempty"`
	Status        int             `json:"status,omitempty"`
	Headers       []field         `json:"headers"`
	Content       string          `json:"content"`
	Trailers      []field         `json:"trailers"`
}

type informational struct {
	Status  int     `json:"status"`
	Headers []field `json:"headers"`
}

func hexString(s string) string { return hex.EncodeToString([]byte(s)) }

// net/http keeps fields in a map, so their order is lost and their names are
// canonicalized. The driver compares them accordingly.
func fields(h http.Header) []field {
	names := make([]string, 0, len(h))
	for name := range h {
		names = append(names, name)
	}
	sort.Strings(names)
	result := []field{}
	for _, name := range names {
		for _, value := range h[name] {
			result = append(result, field{hexString(strings.ToLower(name)), hexString(value)})
		}
	}
	return result
}

func header(fs []field) (http.Header, error) {
	h := http.Header{}
	for _, f := range fs {
		name, err := unhex(f[0])
		if err != nil {
			return nil, err
		}
		value, err := unhex(f[1])
		if err != nil {
			return nil, err
		}
		h.Add(string(name), string(value))
	}
	return h, nil
}

func bhttpDecode(r request) (any, error) {
	data, err := unhex(r.Message)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, rejected(fmt.Errorf("empty message"))
	}
	switch data[0] {
	case 0:
		req, err := ohttp.UnmarshalBinaryRequest(data)
		if err != nil {
			return nil, rejected(err)
		}
		body, _ := io.ReadAll(req.Body)
		path := req.URL.EscapedPath()
		if req.URL.RawQuery != "" {
			path += "?" + req.URL.RawQuery
		}
		return map[string]any{"decoded": message{
			Kind: "request", Method: hexString(req.Method), Scheme: hexString(req.URL.Scheme),
			Authority: hexString(req.URL.Host), Path: hexString(path),
			Headers: fields(req.Header), Content: hex.EncodeToString(body), Trailers: fields(req.Trailer),
		}}, nil
	case 1:
		resp, err := ohttp.UnmarshalBinaryResponse(data)
		if err != nil {
			return nil, rejected(err)
		}
		body, _ := io.ReadAll(resp.Body)
		return map[string]any{"decoded": message{
			Kind: "response", Status: resp.StatusCode,
			Headers: fields(resp.Header), Content: hex.EncodeToString(body), Trailers: fields(resp.Trailer),
		}}, nil
	case 2, 3:
		return nil, unsupported("indeterminate-length messages")
	default:
		return nil, rejected(fmt.Errorf("framing indicator %d", data[0]))
	}
}

func bhttpEncode(r request) (any, error) {
	if r.Framing != "known" {
		return nil, unsupported("indeterminate-length messages")
	}
	var m message
	if err := json.Unmarshal(r.Decoded, &m); err != nil {
		return nil, internal("invalid message: %v", err)
	}
	if len(m.Trailers) > 0 || len(m.Informational) > 0 {
		return nil, unsupported("trailers and informational responses")
	}
	h, err := header(m.Headers)
	if err != nil {
		return nil, err
	}
	content, err := unhex(m.Content)
	if err != nil {
		return nil, err
	}
	var encoded []byte
	switch m.Kind {
	case "request":
		var parts [4]string
		for i, s := range []string{m.Method, m.Scheme, m.Authority, m.Path} {
			b, err := unhex(s)
			if err != nil {
				return nil, err
			}
			parts[i] = string(b)
		}
		req, err := http.NewRequest(parts[0], parts[1]+"://"+parts[2]+parts[3], bytes.NewReader(content))
		if err != nil {
			return nil, rejected(err)
		}
		req.Header = h
		binary := ohttp.BinaryRequest(*req)
		encoded, err = binary.Marshal()
		if err != nil {
			return nil, rejected(err)
		}
	case "response":
		resp := &http.Response{StatusCode: m.Status, Header: h, Body: io.NopCloser(bytes.NewReader(content))}
		binary := ohttp.CreateBinaryResponse(resp)
		encoded, err = binary.Marshal()
		if err != nil {
			return nil, rejected(err)
		}
	default:
		return nil, internal("unknown kind %q", m.Kind)
	}
	return map[string]any{"message": hex.EncodeToString(encoded)}, nil
}

func handle(r request) (any, error) {
	switch r.Op {
	case "hello":
		return map[string]any{
			"name": "ohttp-go", "version": moduleVersion, "protocol": 1,
			"kems":  []int{0x0010, 0x0011, 0x0012, 0x0020},
			"kdfs":  []int{1, 2, 3},
			"aeads": []int{1, 2, 3},
			// What this implementation can do beyond the common core.
			"features": []string{},
		}, nil

	case "config_derive":
		config, err := privateConfig(r)
		if err != nil {
			return nil, err
		}
		return map[string]any{"config": hex.EncodeToString(config.Config().Marshal())}, nil

	case "config_parse":
		if r.ConfigList != nil {
			return nil, unsupported("the application/ohttp-keys list form")
		}
		data, err := unhex(r.Config)
		if err != nil {
			return nil, err
		}
		config, err := ohttp.UnmarshalPublicConfig(data)
		if err != nil {
			return nil, rejected(err)
		}
		return map[string]any{"configs": []string{hex.EncodeToString(config.Marshal())}}, nil

	case "client_encapsulate":
		data, err := unhex(r.Config)
		if err != nil {
			return nil, err
		}
		config, err := ohttp.UnmarshalPublicConfig(data)
		if err != nil {
			return nil, rejected(err)
		}
		plaintext, err := unhex(r.Request)
		if err != nil {
			return nil, err
		}
		encapsulated, context, err := ohttp.NewDefaultClient(config).EncapsulateRequest(plaintext)
		if err != nil {
			return nil, rejected(err)
		}
		h := nextHandle
		nextHandle++
		clientContexts[h] = context
		return map[string]any{"enc_request": hex.EncodeToString(encapsulated.Marshal()), "handle": h}, nil

	case "client_decapsulate":
		context, ok := clientContexts[r.Handle]
		if !ok {
			return nil, internal("unknown handle %d", r.Handle)
		}
		delete(clientContexts, r.Handle)
		data, err := unhex(r.EncResponse)
		if err != nil {
			return nil, err
		}
		encapsulated, err := ohttp.UnmarshalEncapsulatedResponse(data)
		if err != nil {
			return nil, rejected(err)
		}
		plaintext, err := context.DecapsulateResponse(encapsulated)
		if err != nil {
			return nil, rejected(err)
		}
		return map[string]any{"response": hex.EncodeToString(plaintext)}, nil

	case "gateway_decapsulate":
		config, err := privateConfig(r)
		if err != nil {
			return nil, err
		}
		data, err := unhex(r.EncRequest)
		if err != nil {
			return nil, err
		}
		encapsulated, err := ohttp.UnmarshalEncapsulatedRequest(data)
		if err != nil {
			return nil, rejected(err)
		}
		plaintext, context, err := ohttp.NewDefaultGateway([]ohttp.PrivateConfig{config}).DecapsulateRequest(encapsulated)
		if err != nil {
			return nil, rejected(err)
		}
		h := nextHandle
		nextHandle++
		gatewayContexts[h] = context
		return map[string]any{"request": hex.EncodeToString(plaintext), "handle": h}, nil

	case "gateway_encapsulate":
		context, ok := gatewayContexts[r.Handle]
		if !ok {
			return nil, internal("unknown handle %d", r.Handle)
		}
		delete(gatewayContexts, r.Handle)
		plaintext, err := unhex(r.Response)
		if err != nil {
			return nil, err
		}
		encapsulated, err := context.EncapsulateResponse(plaintext)
		if err != nil {
			return nil, rejected(err)
		}
		return map[string]any{"enc_response": hex.EncodeToString(encapsulated.Marshal())}, nil

	case "bhttp_decode":
		return bhttpDecode(r)

	case "bhttp_encode":
		return bhttpEncode(r)

	default:
		return nil, unsupported("operation %q", r.Op)
	}
}

// A panic inside the library is an answer too, and must not end the session.
func answer(r request) (result any, err error) {
	defer func() {
		if p := recover(); p != nil {
			result, err = nil, peerError{"internal", fmt.Sprintf("panic: %v", p)}
		}
	}()
	return handle(r)
}

func main() {
	reader := bufio.NewReaderSize(os.Stdin, 1<<20)
	writer := bufio.NewWriter(os.Stdout)
	for {
		// Not a Scanner: its lines are limited to 64 KiB.
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			var r request
			out := map[string]any{}
			if jsonErr := json.Unmarshal(line, &r); jsonErr != nil {
				out["ok"] = false
				out["error"] = map[string]string{"kind": "internal", "message": jsonErr.Error()}
			} else {
				out["id"] = r.ID
				result, opErr := answer(r)
				if opErr != nil {
					kind := "internal"
					if pe, ok := opErr.(peerError); ok {
						kind = pe.kind
					}
					out["ok"] = false
					out["error"] = map[string]string{"kind": kind, "message": opErr.Error()}
				} else {
					out["ok"] = true
					for k, v := range result.(map[string]any) {
						out[k] = v
					}
				}
			}
			encoded, _ := json.Marshal(out)
			writer.Write(encoded)
			writer.WriteByte('\n')
			writer.Flush()
		}
		if err != nil {
			return
		}
	}
}
