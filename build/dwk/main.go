// dwk (Derive WebUI Key) prints the salt and the PBKDF2-HMAC-SHA512 key that qBittorrent
// stores in WebUI\Password_PBKDF2 as "@ByteArray(<salt>:<key>)", both base64 encoded.
//
// The password is read from stdin so it never appears in /proc/<pid>/cmdline.
package main

import (
	"bytes"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"strconv"
)

const (
	defaultIterations = 100000
	saltLength        = 16
	keyLength         = 64
)

func main() {
	if len(os.Args) > 3 || (len(os.Args) > 1 && (os.Args[1] == "-h" || os.Args[1] == "--help")) {
		fmt.Fprintln(os.Stderr, "Usage:", os.Args[0], "[<salt (base64)>] [<iterations>] < password")
		os.Exit(1)
	}

	password, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read password from stdin: %v\n", err)
		os.Exit(1)
	}
	password = bytes.TrimSuffix(password, []byte("\n"))
	password = bytes.TrimSuffix(password, []byte("\r"))

	var salt []byte
	if len(os.Args) > 1 {
		salt, err = base64.StdEncoding.DecodeString(os.Args[1])
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to decode salt from base64: %v\n", err)
			os.Exit(1)
		}
	} else {
		salt = make([]byte, saltLength)
		if _, err = rand.Read(salt); err != nil {
			fmt.Fprintf(os.Stderr, "Failed to generate salt: %v\n", err)
			os.Exit(1)
		}
	}

	iterations := defaultIterations
	if len(os.Args) > 2 {
		iterations, err = strconv.Atoi(os.Args[2])
		if err != nil || iterations < 1 {
			fmt.Fprintf(os.Stderr, "Invalid iterations count %q\n", os.Args[2])
			os.Exit(1)
		}
	}

	dk, err := pbkdf2.Key(sha512.New, string(password), salt, iterations, keyLength)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to derive key: %v\n", err)
		os.Exit(1)
	}

	fmt.Println(base64.StdEncoding.EncodeToString(salt))
	fmt.Println(base64.StdEncoding.EncodeToString(dk))
}