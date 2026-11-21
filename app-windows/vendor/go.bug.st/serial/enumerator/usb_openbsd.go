//
// Copyright 2014-2026 Cristian Maglie. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//

package enumerator

func nativeGetDetailedPortsList(_ func(vid, pid string) bool) ([]*PortDetails, error) {
	// TODO
	return nil, &PortEnumerationError{}
}
