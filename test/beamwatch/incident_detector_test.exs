defmodule BeamWatch.IncidentDetectorTest do
  use ExUnit.Case, async: true

  alias BeamWatch.{IncidentDetector, LogEvent, LogParser}

  defp parse!(line, source) do
    {:ok, event} = LogParser.parse_line(line, source)
    event
  end

  defp state, do: IncidentDetector.new_state()

  describe "container restart loop" do
    test "no incident with fewer than 4 die events" do
      events = [
        parse!("2026-06-05T15:04:00Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:15Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:34Z container=plex event=die exit_code=137", "docker.log")
      ]

      {all_actions, _state} =
        Enum.reduce(events, {[], state()}, fn event, {acc_actions, s} ->
          {actions, new_s} = IncidentDetector.process_event(event, s)
          {acc_actions ++ actions, new_s}
        end)

      assert all_actions == []
    end

    test "opens incident on 4th die event within 60 seconds" do
      events = [
        parse!("2026-06-05T15:04:00Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:15Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:34Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:55Z container=plex event=die exit_code=137", "docker.log")
      ]

      {all_actions, _state} =
        Enum.reduce(events, {[], state()}, fn event, {acc, s} ->
          {actions, new_s} = IncidentDetector.process_event(event, s)
          {acc ++ actions, new_s}
        end)

      assert [{:open, attrs}] = all_actions
      assert attrs.type == :container_restart_loop
      assert attrs.resource == "plex"
      assert attrs.severity == :critical
    end

    test "updates existing incident on 5th die event" do
      events = [
        parse!("2026-06-05T15:04:00Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:15Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:34Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:55Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:05:10Z container=plex event=die exit_code=137", "docker.log")
      ]

      {all_actions, _state} =
        Enum.reduce(events, {[], state()}, fn event, {acc, s} ->
          {actions, new_s} = IncidentDetector.process_event(event, s)
          {acc ++ actions, new_s}
        end)

      open_count = Enum.count(all_actions, &match?({:open, _}, &1))
      update_count = Enum.count(all_actions, &match?({:update, _, _}, &1))
      assert open_count == 1
      assert update_count == 1
    end

    test "no incident when 4 die events span more than 60 seconds" do
      events = [
        parse!("2026-06-05T15:04:00Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:15Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:04:34Z container=plex event=die exit_code=137", "docker.log"),
        parse!("2026-06-05T15:05:20Z container=plex event=die exit_code=137", "docker.log")
      ]

      {all_actions, _state} =
        Enum.reduce(events, {[], state()}, fn event, {acc, s} ->
          {actions, new_s} = IncidentDetector.process_event(event, s)
          {acc ++ actions, new_s}
        end)

      assert all_actions == []
    end

    test "benign single die event does not open incident" do
      event =
        parse!(
          "2026-06-05T15:09:00Z container=home-assistant event=die exit_code=0",
          "docker.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())
      assert actions == []
    end
  end

  describe "disk SMART warning" do
    test "opens incident on first SMART warning" do
      event =
        parse!(
          "2026-06-05T15:06:00Z emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10",
          "syslog.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())

      assert [{:open, attrs}] = actions
      assert attrs.type == :disk_smart_warning
      assert attrs.resource == "disk3"
      assert attrs.severity == :warning
    end

    test "updates incident on repeated SMART warning same disk same day" do
      e1 =
        parse!(
          "2026-06-05T15:06:00Z emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10",
          "syslog.log"
        )

      e2 =
        parse!(
          "2026-06-05T15:06:18Z emhttpd: disk3 SMART warning: Current_Pending_Sector raw=2 threshold=0",
          "syslog.log"
        )

      {a1, s1} = IncidentDetector.process_event(e1, state())
      {a2, _s2} = IncidentDetector.process_event(e2, s1)

      assert [{:open, _}] = a1
      assert [{:update, _id, _line}] = a2
    end

    test "auto-resolves incident when SMART check passed is seen" do
      e1 =
        parse!(
          "2026-06-05T15:06:00Z emhttpd: disk3 SMART warning: Reallocated_Sector_Ct raw=28 threshold=10",
          "syslog.log"
        )

      e2 =
        parse!("2026-06-05T15:25:00Z emhttpd: disk3 SMART check passed", "syslog.log")

      {[{:open, %{id: id}}], s1} = IncidentDetector.process_event(e1, state())
      {actions, _s2} = IncidentDetector.process_event(e2, s1)

      assert [{:resolve, ^id}] = actions
    end

    test "benign SMART check passed for disk with no open incident produces no action" do
      event = parse!("2026-06-05T15:10:10Z emhttpd: disk1 SMART check passed", "syslog.log")
      {actions, _state} = IncidentDetector.process_event(event, state())
      assert actions == []
    end
  end

  describe "share permission failure" do
    test "opens incident on SMB permission denied" do
      event =
        parse!(
          "2026-06-05T15:07:00Z smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private",
          "smb.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())

      assert [{:open, attrs}] = actions
      assert attrs.type == :share_permission_failure
      assert attrs.resource == "media"
      assert attrs.severity == :warning
    end

    test "opens incident on NFS permission denied" do
      event =
        parse!(
          "2026-06-05T15:07:06Z nfsd: permission denied share=media client=192.168.1.12",
          "nfs.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())

      assert [{:open, attrs}] = actions
      assert attrs.type == :share_permission_failure
      assert attrs.resource == "media"
    end

    test "updates existing incident on repeated denial for same share" do
      e1 =
        parse!(
          "2026-06-05T15:07:00Z smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private",
          "smb.log"
        )

      e2 =
        parse!(
          "2026-06-05T15:07:18Z smbd[8112]: Permission denied share=media user=guest path=/mnt/user/media/private",
          "smb.log"
        )

      {[{:open, _}], s1} = IncidentDetector.process_event(e1, state())
      {actions, _s2} = IncidentDetector.process_event(e2, s1)

      assert [{:update, _id, _line}] = actions
    end

    test "benign share access does not open incident" do
      event =
        parse!(
          "2026-06-05T15:11:00Z smbd[8220]: user=alex opened share=backups path=/mnt/user/backups",
          "smb.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())
      assert actions == []
    end
  end

  describe "VM boot failure" do
    test "opens incident on vm start status=failed" do
      event =
        parse!(
          ~s(2026-06-05T15:08:00Z vm=windows11 action=start status=failed reason="cannot access storage image"),
          "libvirt.log"
        )

      {actions, _state} = IncidentDetector.process_event(event, state())

      assert [{:open, attrs}] = actions
      assert attrs.type == :vm_boot_failure
      assert attrs.resource == "windows11"
      assert attrs.severity == :critical
    end

    test "auto-resolves incident when vm start status=running is seen" do
      e1 =
        parse!(
          ~s(2026-06-05T15:08:00Z vm=windows11 action=start status=failed reason="missing image"),
          "libvirt.log"
        )

      e2 =
        parse!("2026-06-05T15:12:08Z vm=windows11 action=start status=running", "libvirt.log")

      {[{:open, %{id: id}}], s1} = IncidentDetector.process_event(e1, state())
      {actions, _s2} = IncidentDetector.process_event(e2, s1)

      assert [{:resolve, ^id}] = actions
    end

    test "benign VM running with no prior failure produces no action" do
      event =
        parse!("2026-06-05T15:13:00Z vm=debian-dev action=start status=running", "libvirt.log")

      {actions, _state} = IncidentDetector.process_event(event, state())
      assert actions == []
    end

    test "adds qemu supporting evidence to open VM boot failure incident" do
      e1 =
        parse!(
          ~s(2026-06-05T15:08:00Z vm=windows11 action=start status=failed reason="missing image"),
          "libvirt.log"
        )

      e2 =
        parse!(
          "2026-06-05T15:08:04Z qemu-system-x86_64: -drive file=/mnt/user/domains/windows11/vdisk1.img: Permission denied",
          "qemu.log"
        )

      {[{:open, %{id: id}}], s1} = IncidentDetector.process_event(e1, state())
      {actions, _s2} = IncidentDetector.process_event(e2, s1)

      assert [{:update, ^id, _line}] = actions
    end
  end
end
