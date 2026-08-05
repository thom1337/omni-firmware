# omni.zsh-theme -- the prompt for the Avast Omni.
#
# Installed to /usr/share/omni/zsh/themes/ and selected by /root/.zshrc, which
# points $ZSH_CUSTOM at /usr/share/omni/zsh. It is NOT inside the oh-my-zsh
# tree: that tree is replaced wholesale whenever the pin in
# rootfs/build-rootfs.sh moves, and anything of ours living inside it would be
# replaced with it.
#
# THE POINT IS THE SLOT, same as /etc/update-motd.d/00-omni-banner. The banner
# tells you which slot you are on once, at login, and then scrolls off the top
# of a 115200 baud console. This puts it on every line you type. The number of
# ways to lose an hour by typing the right command on the wrong slot is large,
# and "I thought I was on B" is the most common of them.
#
# COST: this file runs its detection ONCE, at shell start, and the prompt
# expansion afterwards is three parameter substitutions. Nothing here shells
# out per prompt. That matters -- the alternative, calling fw_printenv from
# precmd, reads an 8 KB block off /dev/mmcblk0boot0 for every prompt you draw.

# --- which slot is this shell actually running on ---------------------------
#
# From /proc/cmdline, NOT from fw_printenv's mender_boot_part. Those two can
# disagree: mender_boot_part is where the NEXT boot goes, and a slot booted by
# hand from the "=>" prompt has the pointer still aimed somewhere else. What
# you want to know before you type is where you ARE, and root= is that.
() {
  local cmdline run=''
  # A read, not a subshell running sed: /proc/cmdline is one short line and
  # $(<file) is a builtin in zsh.
  cmdline=$(</proc/cmdline) 2>/dev/null
  if [[ $cmdline == *root=/dev/mmcblk0p<->* ]]; then
    run=${${cmdline##*root=/dev/mmcblk0p}%%[^0-9]*}
  fi

  case $run in
    1) omni_slot='A'        ; omni_slot_colour='green'  ;;
    2) omni_slot='B'        ; omni_slot_colour='green'  ;;
    7) omni_slot='RECOVERY' ; omni_slot_colour='red'    ;;
    '') omni_slot='?'       ; omni_slot_colour='yellow' ;;
    *) omni_slot="p$run"    ; omni_slot_colour='yellow' ;;
  esac

  # p7 gets the loud treatment. Recovery has no overlay and no A/B semantics,
  # nothing you change there survives a normal boot, and the tools behave
  # differently on it (omni-commit.sh refuses outright) -- see Appendix D of
  # docs/RUNBOOK.md. A green "B" and a red "RECOVERY" should not be
  # distinguishable only by reading carefully.
  if [[ $run == 7 ]]; then
    omni_slot_tag="%B%F{red}[${omni_slot}]%f%b"
  elif [[ -z $run ]]; then
    omni_slot_tag="%F{${omni_slot_colour}}[slot ${omni_slot}]%f"
  else
    omni_slot_tag="%F{${omni_slot_colour}}[${omni_slot} p${run}]%f"
  fi
}

# --- the prompt -------------------------------------------------------------
#
# Deliberately ASCII. The login banner can afford box-drawing characters
# because it prints once and a mangled banner costs nothing; a prompt that
# renders as garbage on somebody's serial adapter costs you the session. The
# console is C.UTF-8 (/etc/locale.conf) but the thing on the other end of the
# cable is whatever the operator had in a drawer.
#
# %(?..) prints the exit status only when it is non-zero. On a console with no
# scrollback worth the name, a failure you did not notice is a failure you
# repeat.
#
# The slot tag is interpolated ONCE, here, rather than left as a ${...}
# reference in the prompt string. A reference would only expand if PROMPT_SUBST
# happened to be set -- it is not set by default, and whether Oh My Zsh sets it
# is a property of whichever upstream commit the build is pinned to. A prompt
# that reads "${omni_slot_tag} omni ~#" on a console is a bug you find in the
# field. Interpolating also means zsh does no parameter expansion per prompt.
#
# Double quotes for the tag, single for the rest: the remainder is full of
# prompt escapes ("%(?..%F{red}%? )") that must reach zsh uninterpreted.
PROMPT="${omni_slot_tag} "'%F{cyan}%m%f %F{white}%~%f %(?..%F{red}%? )%(!.#.$) '

# Empty on purpose: an 80-column serial line has no room for a right prompt,
# and zsh redraws it on every keystroke that reaches the right margin.
RPROMPT=''
