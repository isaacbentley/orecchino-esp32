//
// Copyright 2014-2026 Cristian Maglie. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//

package enumerator

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"go.bug.st/serial"
)

func nativeGetDetailedPortsList(_ func(vid, pid string) bool) ([]*PortDetails, error) {
	// Retrieve the port list.
	// Note: on Linux all the USB details (including Configuration, Manufacturer
	// and Product) are read from sysfs, which is populated by the kernel at
	// enumeration time and does not require actively probing the device, so
	// the active-probe filter is not needed on this platform.
	ports, err := serial.GetPortsList()
	if err != nil {
		return nil, &PortEnumerationError{causedBy: err}
	}

	var res []*PortDetails
	for _, port := range ports {
		details, err := nativeGetPortDetails(port)
		if err != nil {
			return nil, &PortEnumerationError{causedBy: err}
		}
		res = append(res, details)
	}
	return res, nil
}

func nativeGetPortDetails(portPath string) (*PortDetails, error) {
	portName := filepath.Base(portPath)
	devicePath := fmt.Sprintf("/sys/class/tty/%s/device", portName)
	if _, err := os.Stat(devicePath); err != nil {
		return &PortDetails{}, nil
	}
	realDevicePath, err := filepath.EvalSymlinks(devicePath)
	if err != nil {
		return nil, fmt.Errorf("Can't determine real path of %s: %s", devicePath, err.Error())
	}
	subSystemPath, err := filepath.EvalSymlinks(filepath.Join(realDevicePath, "subsystem"))
	if err != nil {
		return nil, fmt.Errorf("Can't determine real path of %s: %s", filepath.Join(realDevicePath, "subsystem"), err.Error())
	}
	subSystem := filepath.Base(subSystemPath)

	result := &PortDetails{Name: portPath}
	switch subSystem {
	case "usb-serial":
		err := parseUSBSysFS(filepath.Dir(filepath.Dir(realDevicePath)), result)
		return result, err
	case "usb":
		err := parseUSBSysFS(filepath.Dir(realDevicePath), result)
		return result, err
	// TODO: other cases?
	default:
		return result, nil
	}
}

func parseUSBSysFS(usbDevicePath string, details *PortDetails) error {
	vid, err := readLine(filepath.Join(usbDevicePath, "idVendor"))
	if err != nil {
		return err
	}
	pid, err := readLine(filepath.Join(usbDevicePath, "idProduct"))
	if err != nil {
		return err
	}
	serial, err := readLine(filepath.Join(usbDevicePath, "serial"))
	if err != nil {
		return err
	}

	configuration, _ := readLine(filepath.Join(usbDevicePath, "configuration"))
	// It's not an error if the configuration file is not present, so we ignore it.

	manufacturer, err := readLine(filepath.Join(usbDevicePath, "manufacturer"))
	if err != nil {
		return err
	}
	product, err := readLine(filepath.Join(usbDevicePath, "product"))
	if err != nil {
		return err
	}

	details.IsUSB = true
	// sysfs reports idVendor/idProduct in lowercase hex; the darwin and Windows
	// backends report them uppercase. Normalize to uppercase so VID/PID are
	// consistent across platforms.
	details.VID = strings.ToUpper(vid)
	details.PID = strings.ToUpper(pid)
	details.SerialNumber = serial
	details.Configuration = configuration
	details.Manufacturer = manufacturer
	details.Product = product
	return nil
}

func readLine(filename string) (string, error) {
	file, err := os.Open(filename)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer file.Close()
	reader := bufio.NewReader(file)
	line, _, err := reader.ReadLine()
	if err == io.EOF {
		// An empty sysfs attribute file (e.g. an empty "serial",
		// "manufacturer" or "product") yields io.EOF with no data.
		// Treat it as an empty value, not an error, so a single device
		// with a blank attribute does not abort the whole enumeration.
		return "", nil
	}
	return string(line), err
}
