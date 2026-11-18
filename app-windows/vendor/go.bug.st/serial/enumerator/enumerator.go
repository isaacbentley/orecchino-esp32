//
// Copyright 2014-2026 Cristian Maglie. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//

package enumerator

//go:generate go run golang.org/x/sys/windows/mkwinsyscall -output syscall_windows.go usb_windows.go

// PortDetails contains detailed information about USB serial port.
// Use GetDetailedPortsList function to retrieve it.
type PortDetails struct {
	// Name is the port address, like COM1 on Windows or /dev/ttyUSB0 on Linux.
	Name string
	// IsUSB is true if the port is a USB serial port, false otherwise.
	IsUSB bool
	// VID is the USB Vendor ID, when available.
	VID string
	// PID is the USB Product ID, when available.
	PID string
	// SerialNumber is the USB serial number, when available.
	SerialNumber string
	// Configuration is the USB configuration string, when available.
	// Requires active USB probing enabled.
	Configuration string
	// Manufacturer is the USB iManufacturer string, when available.
	// Requires active USB probing enabled.
	Manufacturer string
	// Product is the USB iProduct string, when available.
	// Requires active USB probing enabled.
	Product string
}

// All is a vid/pid filter that accepts all devices
var All = func(vid, pid string) bool { return true }

// GetDetailedPortsList retrieve ports details like USB VID/PID.
// Please note that this function may not be available on all OS:
// in that case a FunctionNotImplemented error is returned.
//
// Getting some USB fields requires active USB probing (see PortDetails
// struct), which may interfere with correct operation on some devices.
// Active USB probing is disabled by default, to enable it you must provide
// at least one filter function to allow the probing of specific devices based on
// vid and pid. If no filters are provided then no devices will be actively probed.
// If a device match any of the filters provided then the device will be actively probed.
func GetDetailedPortsList(activeUSBProbeFilters ...func(vid, pid string) bool) ([]*PortDetails, error) {
	return nativeGetDetailedPortsList(func(vid, pid string) bool {
		for _, filter := range activeUSBProbeFilters {
			if filter(vid, pid) {
				return true
			}
		}
		return false
	})
}

// PortEnumerationError is the error type for serial ports enumeration
type PortEnumerationError struct {
	causedBy error
}

// Error returns the complete error code with details on the cause of the error
func (e PortEnumerationError) Error() string {
	reason := "Error while enumerating serial ports"
	if e.causedBy != nil {
		reason += ": " + e.causedBy.Error()
	}
	return reason
}
