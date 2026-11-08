// ─── ddvcap: minimal packet capture for the Android rig (FAN, 2026-11-08) ───
// The emulator's console capture misses the phone's Wi-Fi traffic and the image has no tcpdump, so the Android
// adapter (plat/android.sh) runs this as root on the phone: AF_PACKET bound to one interface, written as pcap
// (Ethernet link type) until SIGINT/SIGTERM. Build static for the phone's arch, e.g.
//   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o ddvcap .
// Usage: ddvcap <interface> <out.pcap>
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const ethPAll = 0x0003

func htons(v uint16) uint16 { return v<<8 | v>>8 }

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: ddvcap <interface> <out.pcap>")
		os.Exit(2)
	}
	ifi, err := net.InterfaceByName(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: interface %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(htons(ethPAll)))
	if err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: socket (needs root): %v\n", err)
		os.Exit(1)
	}
	if err := syscall.Bind(fd, &syscall.SockaddrLinklayer{Protocol: htons(ethPAll), Ifindex: ifi.Index}); err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: bind %s: %v\n", ifi.Name, err)
		os.Exit(1)
	}
	// 1 s receive timeout so a stop signal is seen even on a quiet link.
	tv := syscall.Timeval{Sec: 1}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: timeout: %v\n", err)
		os.Exit(1)
	}
	f, err := os.Create(os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: %v\n", err)
		os.Exit(1)
	}
	w := bufio.NewWriter(f)
	hdr := make([]byte, 24)
	binary.LittleEndian.PutUint32(hdr[0:], 0xa1b2c3d4)
	binary.LittleEndian.PutUint16(hdr[4:], 2)
	binary.LittleEndian.PutUint16(hdr[6:], 4)
	binary.LittleEndian.PutUint32(hdr[16:], 65535)
	binary.LittleEndian.PutUint32(hdr[20:], 1) // LINKTYPE_ETHERNET
	if _, err := w.Write(hdr); err != nil {
		fmt.Fprintf(os.Stderr, "ddvcap: write header: %v\n", err)
		os.Exit(1)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	buf := make([]byte, 65536)
	rec := make([]byte, 16)
	n := 0
	for {
		select {
		case <-stop:
			if err := w.Flush(); err != nil {
				fmt.Fprintf(os.Stderr, "ddvcap: flush: %v\n", err)
			}
			if err := f.Close(); err != nil {
				fmt.Fprintf(os.Stderr, "ddvcap: close: %v\n", err)
			}
			fmt.Fprintf(os.Stderr, "ddvcap: %d packets\n", n)
			return
		default:
		}
		l, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			if err == syscall.EAGAIN || err == syscall.EINTR {
				continue
			}
			fmt.Fprintf(os.Stderr, "ddvcap: recv: %v\n", err)
			_ = w.Flush()
			os.Exit(1)
		}
		now := time.Now()
		binary.LittleEndian.PutUint32(rec[0:], uint32(now.Unix()))
		binary.LittleEndian.PutUint32(rec[4:], uint32(now.Nanosecond()/1000))
		binary.LittleEndian.PutUint32(rec[8:], uint32(l))
		binary.LittleEndian.PutUint32(rec[12:], uint32(l))
		if _, err := w.Write(rec); err != nil {
			fmt.Fprintf(os.Stderr, "ddvcap: write: %v\n", err)
			os.Exit(1)
		}
		if _, err := w.Write(buf[:l]); err != nil {
			fmt.Fprintf(os.Stderr, "ddvcap: write: %v\n", err)
			os.Exit(1)
		}
		n++
		// Flush often: a kill -9 must still leave a readable file.
		if n%32 == 0 {
			_ = w.Flush()
		}
	}
}
