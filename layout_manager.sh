#!/bin/bash
# Author: klaxalk (klaxalk@gmail.com, github.com/klaxalk)
#
# Dependencies:
# - awk+sed+cat ...
# - i3-msg    : i3 tui
# - jq        : json manipulation
# - rofi      : nice dmenu alternative
# - sponge    : because jq can't -i
# - xdotool   : window manipulation
# - xrandr    : getting info of current monitor
#
# vim: set foldmarker=#\ #{,#\ #}

# #{ CHECK DEPENDENCIES

JQ_BIN="$(whereis -b jq | awk '{print $2}')"
ROFI_BIN="$(whereis -b rofi | awk '{print $2}')"
SPONGE_BIN="$(whereis -b sponge | awk '{print $2}')"
XDOTOOL_BIN="$(whereis -b xdotool | awk '{print $2}')"
XRANDR_BIN="$(whereis -b xrandr | awk '{print $2}')"

if [ -z "$JQ_BIN" ]; then
  echo missing jq, please install dependencies
  exit 1
fi

if [ -z "$ROFI_BIN" ]; then
  echo missing rofi, please install dependencies
  exit 1
fi

if [ -z "$SPONGE_BIN" ]; then
  echo missing sponge, please install dependencies
  exit 1
fi

if [ -z "$XDOTOOL_BIN" ]; then
  echo missing xdotool, please install dependencies
  exit 1
fi

if [ -z "$XRANDR_BIN" ]; then
  echo missing xrandr, please install dependencies
  exit 1
fi

# #}

if [ -z "$XDG_CONFIG_HOME" ]; then
  LAYOUT_PATH=~/.layouts
else
  LAYOUT_PATH="$XDG_CONFIG_HOME/i3-layout-manager/layouts"
fi

# make directory for storing layouts
mkdir -p $LAYOUT_PATH > /dev/null 2>&1

# logs
LOG_FILE=/tmp/i3_layout_manager.txt
echo "" > "$LOG_FILE"

# #{ ASK FOR THE ACTION

# if operating using dmenu
if [ -z $1 ]; then

  ACTION=$(echo -e "LOAD LAYOUT\nSAVE LAYOUT\nDELETE LAYOUT" |
    rofi -i -dmenu -no-custom -p "Select action")

  if [ -z "$ACTION" ]; then
    exit
  fi

  # get me layout names based on existing file names in the LAYOUT_PATH
  LAYOUT_NAMES=$(ls -Rt $LAYOUT_PATH |
    grep "layout.*json" |
    sed -nr 's/layout-(.*)\.json/\1/p' |
    sed 's/\s/\n/g' |
    sed 's/_/ /g')
  LAYOUT_NAME=$(echo "$LAYOUT_NAMES" |
    rofi -i -dmenu -p "Select layout (you may type new name when creating)" |
    sed 's/\s/_/g')
  LAYOUT_NAME=${LAYOUT_NAME^^} # upper case

# getting argument from command line
else

  ACTION="LOAD LAYOUT"
  # if the layout name is a full path, just pass it, otherwise convert it to upper case
  if [[ "${1}" == *".json" ]]; then
    LAYOUT_NAME="${1}"
  else
    LAYOUT_NAME="${1^^}"
  fi

fi

# no action, exit
if [ -z "$LAYOUT_NAME" ]; then
  exec "$0" "$@"
fi

# #}

# if the layout name is a full path, use it, otherwise fabricate the full path
if [[ $LAYOUT_NAME == *".json" ]]; then
  LAYOUT_FILE=`realpath "$LAYOUT_NAME"`
else
  LAYOUT_FILE=$LAYOUT_PATH/layout-"$LAYOUT_NAME".json
fi

echo $LAYOUT_FILE

if [ "$ACTION" == "LOAD LAYOUT" ] && [ ! -f "$LAYOUT_FILE" ]; then
  exit
fi

# get current workspace ID
WORKSPACE_ID=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused==true).num')

# #{ LOAD

if [[ "$ACTION" = "LOAD LAYOUT" ]]; then

  # updating the workspace to the new layout is tricky
  # normally it does not influence existing windows
  # For it to apply to existing windows, we need to
  # first remove them from the workspace and then
  # add them back while we remove any empty placeholders
  # which would normally cause mess. The placeholders
  # are recognize by having no process inside them.

  # get the list of windows on the current workspace
  WINDOWS=$(xdotool search --all --onlyvisible --desktop $(xprop -notype -root _NET_CURRENT_DESKTOP | cut -c 24-) "" 2>/dev/null)

  echo "About to unload all windows from the workspace" >> "$LOG_FILE"

  for window in $WINDOWS; do

    HAS_PID=$(xdotool getwindowpid $window 2>&1 | grep "pid" | wc -l)

    echo "Unloading window '$window'" >> "$LOG_FILE"

    if [ ! $HAS_PID -eq 0 ]; then
      echo "Window '$window' does not have a process" >> "$LOG_FILE"
    else
      xdotool windowunmap "$window" >> "$LOG_FILE" 2>&1
      echo "'xdotool windounmap $window' returned $?" >> "$LOG_FILE"
    fi

  done

  echo "" >> "$LOG_FILE"
  echo "About to delete all empty window placeholders" >> "$LOG_FILE"

  # delete all empty layout windows from the workspace
  # we just try to focus any window on the workspace (there should not be any, we unloaded them)
  for (( i=0 ; $a-100 ; a=$a+1 )); do

    # check window for STICKY before killing - if sticky do not kill
    xprop -id $(xdotool getwindowfocus) | grep -q '_NET_WM_STATE_STICK'

    if [ $? -eq 1 ]; then

      echo "Killing an unsued placeholder" >> "$LOG_FILE"
      i3-msg "focus parent, kill" >> "$LOG_FILE" 2>&1

      i3_msg_ret="$?"

      if [ "$i3_msg_ret" == 0 ]; then
        echo "Empty placeholder successfully killed" >> "$LOG_FILE"
      else
        echo "Empty placeholder could not be killed, breaking" >> "$LOG_FILE"
        break
      fi
    fi
  done

  echo "" >> "$LOG_FILE"
  echo "Applying the layout" >> "$LOG_FILE"

  # then we can apply to chosen layout
  i3-msg "append_layout $LAYOUT_FILE" >> "$LOG_FILE" 2>&1

  echo "" >> "$LOG_FILE"
  echo "About to bring all windows back" >> "$LOG_FILE"

  # and then we can reintroduce the windows back to the workspace
  for window in $WINDOWS; do
    HAS_PID=$(xdotool getwindowpid $window 2>&1 | grep "pid" | wc -l)

    echo "Loading back window '$window'" >> "$LOG_FILE"

    if [ ! $HAS_PID -eq 0 ]; then
      echo "$window does not have a process" >> "$LOG_FILE"
    else
      xdotool windowmap "$window"
      echo "'xdotool windowmap $window' returned $?" >> "$LOG_FILE"
    fi
  done

fi

# #}

# #{ SAVE

if [[ "$ACTION" = "SAVE LAYOUT" ]]; then

  ACTION=$(echo -e "DEFAULT (INSTANCE)\nSPECIFIC (CHOOSE)\nMATCH ANY" |
    rofi -i -dmenu -p "How to identify windows? (xprop style)")


  if [[ "$ACTION" = "DEFAULT (INSTANCE)" ]]; then
    CRITERION="default"
  elif [[ "$ACTION" = "SPECIFIC (CHOOSE)" ]]; then
    CRITERION="specific"
  elif [[ "$ACTION" = "MATCH ANY" ]]; then
    CRITERION="any"
  fi


  CURRENT_MONITOR=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused==true).output')

  # Get the index of the active workspace on the active monitor
  INDEX=$(i3-msg -t get_workspaces | jq --arg monitor $CURRENT_MONITOR -r '[.[]| select(.output==$monitor)|.focused==true]|index(true)')
  i3-save-tree --output $CURRENT_MONITOR |
    sed -n '2,$ {/\/\/ [^"]/d; s:// ::; s:\("floating_nodes"\):,\1:; p}' |
    jq --arg index $INDEX -s '.[$index|tonumber]|.type="con"|.fullscreen_mode=0| . as $root |.floating_nodes as $fn|  [($root|del(.floating_nodes)),$fn[]?]' > $LAYOUT_FILE

  # now we have to do some postprocessing on it, all is even advices on the official website
  # https://i3wm.org/docs/layout-saving.html

  if [[ "$CRITERION" = "default" ]]; then
    # instance swallow
    jq 'walk( if type == "object" and has("swallows")
                 then .swallows |= [.[0]|{instance}] 
                 else  . end )' $LAYOUT_FILE | sponge $LAYOUT_FILE
  elif [[ "$CRITERION" = "any" ]]; then
    # instance swallow empty string
    jq 'walk( if type == "object" and has("swallows")
                 then .swallows |= [{"instance":""}] 
                 else  . end )' $LAYOUT_FILE | sponge $LAYOUT_FILE
  elif [[ "$CRITERION" = "specific" ]]; then
    # select criterion
    for path in $(jq -r 'paths(has("swallows")?)|@csv' $LAYOUT_FILE); do
      NAME=$(jq --argjson path "[$path]" 'getpath($path).name' $LAYOUT_FILE)
      SELECTED_OPTION=$(\
        jq -r --argjson path "[$path]" 'getpath($path)|.swallows[0]|to_entries[]|[.key,.value]|@tsv' $LAYOUT_FILE |
        column -t|
        rofi -i -dmenu -no-custom -p "Choose the matching method for ${NAME}"|
        awk '{print $1}')
      # default to instance
      SELECTED_OPTION=${SELECTED_OPTION:-"instance"}
      jq --argjson path "[$path]" --arg option $SELECTED_OPTION \
         '(getpath($path).swallows[0]) as $swallows|(getpath($path).swallows[0])
           = {($option): $swallows[$option]}' $LAYOUT_FILE |
          sponge $LAYOUT_FILE
    done
  fi 
#
  notify-send -u low -t 2000 "Layout saved" -h string:x-canonical-private-synchronous:anything

fi


if [[ "$ACTION" = "DELETE LAYOUT" ]]; then
  rm "$LAYOUT_FILE"
  notify-send -u low -t 2000 "Layout deleted" -h string:x-canonical-private-synchronous:anything
  exec "$0" "$@"
fi
