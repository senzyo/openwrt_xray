# System-wide .bashrc file

# Continue if running interactively
[[ $- == *i* ]] || return 0

[ \! -s /etc/shinit ] || . /etc/shinit

# 以下是自定义内容

PS1='\n'
PS1+='\[\e[1;37m\]'
PS1+='\t '
PS1+='\[\e[1;31m\]'
PS1+='\u'
PS1+='\[\e[1;37m\]'
PS1+='@'
PS1+='\[\e[1;31m\]'
PS1+='\h '
PS1+='\[\e[1;36m\]'
PS1+='$PWD'
PS1+='\n'
PS1+='\[\e[1;31m\]'
PS1+='\$ '
PS1+='\[\e[0m\]'

alias grep="grep --color=auto"
alias ls="ls -F --color=auto"
alias la="ls -aF --color=auto"
alias ll="ls -alF --color=auto"

ch() {
	: >"$HOME/.bash_history"
	history -c
	clear
}

export COLORTERM="truecolor"
export EDITOR="/bin/vi"
