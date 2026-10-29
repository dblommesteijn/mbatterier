package pmset

import (
	"sync"
	"syscall"
	"time"
)

// prefsDir is where the power preferences live. powerd and cfprefsd replace
// those plists by writing a temporary file and renaming it, which is a change
// to the directory rather than to the file the watch would otherwise hold, so
// the directory is what gets watched.
const prefsDir = "/Library/Preferences"

// Changes reports, on the returned channel, that something in the preferences
// directory changed — which a power mode switch made by macOS may have caused.
// It is only a prompt to look again with Get: the directory holds many
// unrelated preferences, so most events are not about the power mode, and a
// burst of writes arrives as one event.
//
// stop releases the watch. The channel is never closed, so a reader selecting
// on it just stops hearing from it.
func Changes() (events <-chan struct{}, stop func(), err error) {
	kq, err := syscall.Kqueue()
	if err != nil {
		return nil, nil, err
	}
	fd, err := syscall.Open(prefsDir, syscall.O_RDONLY, 0)
	if err != nil {
		syscall.Close(kq)
		return nil, nil, err
	}
	ev := syscall.Kevent_t{
		Ident:  uint64(fd),
		Filter: syscall.EVFILT_VNODE,
		Flags:  syscall.EV_ADD | syscall.EV_CLEAR,
		Fflags: syscall.NOTE_WRITE,
	}
	if _, err := syscall.Kevent(kq, []syscall.Kevent_t{ev}, nil, nil); err != nil {
		syscall.Close(fd)
		syscall.Close(kq)
		return nil, nil, err
	}

	out := make(chan struct{}, 1)
	done := make(chan struct{})
	go func() {
		defer syscall.Close(fd)
		defer syscall.Close(kq)
		// A short timeout, so stop is noticed without a wake-up event.
		timeout := syscall.NsecToTimespec(int64(500 * time.Millisecond))
		buf := make([]syscall.Kevent_t, 1)
		for {
			select {
			case <-done:
				return
			default:
			}
			n, err := syscall.Kevent(kq, nil, buf, &timeout)
			if err != nil && err != syscall.EINTR {
				return
			}
			if n > 0 {
				select {
				case out <- struct{}{}:
				default: // one is already pending
				}
			}
		}
	}()
	var once sync.Once
	return out, func() { once.Do(func() { close(done) }) }, nil
}
