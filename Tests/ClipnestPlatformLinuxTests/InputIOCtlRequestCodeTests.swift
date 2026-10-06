import Foundation
import Testing

@testable import ClipnestPlatformLinux

/// Verifies `IOCtlRequestCode`'s formula against the well-documented,
/// widely-cited literal values for `/dev/uinput`'s ioctls (e.g.
/// `UI_DEV_CREATE` == `0x5501`, `UI_SET_EVBIT` == `0x40045564`) — these
/// literals appear throughout uinput tutorials/kernel docs and have been
/// stable for decades, so asserting the formula reproduces them is a real
/// correctness check on the macro reimplementation, not a tautology.
@Suite("IOCtlRequestCode")
struct IOCtlRequestCodeTests {
  @Test("_IO(UINPUT_IOCTL_BASE, 1) == UI_DEV_CREATE's documented 0x5501")
  func ioDevCreate() {
    #expect(IOCtlRequestCode.io(type: 0x55, number: 1) == 0x5501)
  }

  @Test("_IO(UINPUT_IOCTL_BASE, 2) == UI_DEV_DESTROY's documented 0x5502")
  func ioDevDestroy() {
    #expect(IOCtlRequestCode.io(type: 0x55, number: 2) == 0x5502)
  }

  @Test("_IOW(UINPUT_IOCTL_BASE, 100, sizeof(int)) == UI_SET_EVBIT's documented 0x40045564")
  func iowSetEvBit() {
    #expect(IOCtlRequestCode.iow(type: 0x55, number: 100, size: 4) == 0x4004_5564)
  }

  @Test("_IOW(UINPUT_IOCTL_BASE, 101, sizeof(int)) == UI_SET_KEYBIT's documented 0x40045565")
  func iowSetKeyBit() {
    #expect(IOCtlRequestCode.iow(type: 0x55, number: 101, size: 4) == 0x4004_5565)
  }

  @Test("UInputRequestCodes wires the same base/numbers/sizes through")
  func requestCodesMatchFormula() {
    #expect(UInputRequestCodes.devCreate == IOCtlRequestCode.io(type: 0x55, number: 1))
    #expect(UInputRequestCodes.devDestroy == IOCtlRequestCode.io(type: 0x55, number: 2))
    #expect(
      UInputRequestCodes.setEvBit == IOCtlRequestCode.iow(type: 0x55, number: 100, size: 4))
    #expect(
      UInputRequestCodes.setKeyBit == IOCtlRequestCode.iow(type: 0x55, number: 101, size: 4))
  }

  @Test("uinput_setup's ioctl payload size matches the actual encoded buffer size")
  func deviceSetupSizeMatchesEncoding() {
    let encoded = UInputEventEncoding.encodeDeviceSetup(
      busType: 0, vendor: 0, product: 0, version: 0, name: "x", ffEffectsMax: 0)
    #expect(encoded.count == UInputDeviceSetupLayout.byteCount)
  }
}
