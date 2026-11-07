package service

import (
	"encoding/xml"
	"strings"
)

// Service definitions as text. Kept free of build tags so every platform's
// file is unit-tested everywhere.

// launchdPlist renders the user LaunchAgent. The agent lowers its own
// priority at start; launchd only keeps it alive.
func launchdPlist(o Options, logPath string) string {
	var args strings.Builder
	for _, a := range append([]string{o.Binary}, o.agentArgs()...) {
		args.WriteString("        <string>" + xmlEscape(a) + "</string>\n")
	}
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- User LaunchAgent written by "tailmon service install" — NOT root.
         ioreg GPU stats work unprivileged and the agent binds only to the
         Tailscale IP + loopback. -->
    <key>Label</key>
    <string>` + LaunchdLabel + `</string>
    <key>ProgramArguments</key>
    <array>
` + args.String() + `    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>` + xmlEscape(logPath) + `</string>
    <key>StandardErrorPath</key>
    <string>` + xmlEscape(logPath) + `</string>
</dict>
</plist>
`
}

// systemdUnit renders the Linux user unit.
func systemdUnit(o Options) string {
	argv := []string{systemdQuote(o.Binary)}
	for _, a := range o.agentArgs() {
		argv = append(argv, systemdQuote(a))
	}
	return `[Unit]
Description=tailmon agent (tailnet resource monitor)
After=network-online.target

[Service]
ExecStart=` + strings.Join(argv, " ") + `
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=default.target
`
}

func systemdQuote(s string) string {
	if !strings.ContainsAny(s, " \t\"'\\") {
		return s
	}
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}

// windowsTaskXML renders the Task Scheduler definition. It encodes what
// deploy/install-windows.ps1 learned the hard way: Task Scheduler's defaults
// are for finite jobs and silently kill daemons —
//
//	ExecutionTimeLimit PT72H   -> agent terminated after exactly 3 days (PT0S = none)
//	*IfGoingOnBatteries        -> not started / stopped on battery or UPS
//
// plus restart-on-failure (1 min, 3x), IgnoreNew for overlapping starts, and
// priority 7 (BELOW_NORMAL) so training never competes with the agent.
func windowsTaskXML(o Options) string {
	args := strings.Join(o.agentArgs(), " ")
	return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>tailmon agent (tailnet resource monitor) - written by "tailmon service install"</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>` + xmlEscape(o.Binary) + `</Command>
      <Arguments>` + xmlEscape(args) + `</Arguments>
    </Exec>
  </Actions>
</Task>
`
}

func xmlEscape(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}
