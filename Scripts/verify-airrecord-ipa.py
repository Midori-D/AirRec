"""Check the normal-app AX package independently of the legacy test Runner."""
import plistlib
from pathlib import PurePosixPath
import struct
import sys
import zipfile

def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        roots = {name.split('/')[1] for name in names
                 if name.startswith('Payload/') and len(name.split('/')) > 2
                 and name.split('/')[1].endswith('.app')}
        if len(roots) != 1:
            raise ValueError('Expected exactly one normal app.')
        prefix = 'Payload/' + roots.pop() + '/'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleIdentifier') != 'com.calltap.prototype.ictrl':
            raise ValueError('Unexpected app identifier.')
        if info.get('CFBundleShortVersionString') != '1.1.9' or str(info.get('CFBundleVersion')) != '14':
            raise ValueError('Unexpected AX app version.')
        if info.get('CFBundleDisplayName') != 'AirRecord':
            raise ValueError('Unexpected app display name.')
        if info.get('CFBundleExecutable') != 'AirRecord':
            raise ValueError('Unexpected app executable name.')
        if info.get('CallTapDirectOnly'):
            raise ValueError('Experimental direct connection marker must be absent.')
        if any('.appex/' in name or name.rstrip('/').endswith('.appex') for name in names):
            raise ValueError('The location standby app must not contain Helper extensions.')
        if info.get('UIBackgroundModes') != ['location']:
            raise ValueError('Only the location background mode may be declared.')
        usage = info.get('NSLocationWhenInUseUsageDescription')
        if not isinstance(usage, str) or not all(word in usage for word in ('백그라운드', '저장', '전송')):
            raise ValueError('Location standby privacy explanation missing.')
        if any(key.startswith('NSMicrophone') or
               (key.startswith('NSLocation') and key != 'NSLocationWhenInUseUsageDescription') for key in info):
            raise ValueError('Microphone and Always location permissions must be absent.')
        icon = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
        if icon.get('CFBundleIconName') != 'AppIcon':
            raise ValueError('App icon catalog missing.')
        metadata = [name for name in names if name.startswith(prefix+'Metadata.appintents/') and not name.endswith('/')]
        if not metadata or not any(b'ResumeAirRecordMonitoringIntent' in archive.read(name) for name in metadata):
            raise ValueError('Shortcut intent metadata missing.')
        if any(name.endswith('embedded.mobileprovision') or '.xctest/' in name for name in names):
            raise ValueError('Profiles and XCTest plugins must not be distributed.')
        count = 0
        for name in names:
            if not name.startswith(prefix) or name.endswith('/'):
                continue
            binary = archive.read(name)
            if binary[:4] != b'\xcf\xfa\xed\xfe':
                continue
            if b'calltap_direct_connect' in binary:
                raise ValueError('Experimental direct connector must be absent.')
            if len(binary) < 32:
                raise ValueError('Truncated Mach-O.')
            _, cpu, _, _, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
            if cpu != 0x100000c or commands > 4096 or command_bytes > len(binary)-32:
                raise ValueError('Unexpected architecture or invalid load commands.')
            offset, signed = 32, False
            for _ in range(commands):
                command, size = struct.unpack_from('<II', binary, offset)
                if size < 8 or offset+size > 32+command_bytes:
                    raise ValueError('Invalid Mach-O command size.')
                if command in (0xc, 0x80000018, 0x8000001f, 0x80000023):
                    name_offset = struct.unpack_from('<I', binary, offset+8)[0]
                    dependency = binary[offset+name_offset:offset+size].split(b'\0',1)[0]
                    if any(part in dependency for part in (b'XCTest',b'XCUIAutomation',b'Testing.framework')):
                        raise ValueError('An XCTest/testing library is linked.')
                if command == 0x1d:
                    signed = struct.unpack_from('<I', binary, offset+12)[0] > 0
                offset += size
            if not signed:
                raise ValueError('Unsigned embedded Mach-O: ' + PurePosixPath(name).name)
            count += 1
        if count < 1 or prefix+info['CFBundleExecutable'] not in names:
            raise ValueError('Main executable missing.')
        print(f'PASS: AirRecord 1.1.9 (14), location standby permission, AppIcon, Shortcut metadata, {count} signed arm64 binary(s), no Helper/audio/microphone/Always/direct connector/XCTest/profile.')

if __name__ == '__main__':
    verify(sys.argv[1])
