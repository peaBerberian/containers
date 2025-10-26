# Dockerfile
# ==========
#
# This "Dockerfile" sets a basic Ubuntu LTS environment with a shell, the wanted
# node.js version and some CLI tools installed and configured depending on your
# environment variables.
#
# It also copies files you put in the `./configs/` directory inside that
# container's `$HOME`.
#
# It sets most cache directories (e.g. `yarn`, `npm` caches) to a new
# `$HOME/.container-cache` directory and tools' user data (e.g. shell history
# neovim plugins, tools database etc.) to a `$HOME/.container-local` directory.
# It does both to simplify the possibility of persisting those two, but it
# doesn't persist them by itself (this is performed by the `compose.yaml` file).

FROM ubuntu:24.04 AS ubuntu-base

# Configurable user settings
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG USERNAME=dev
ARG USER_SHELL=bash

# Install base packages
RUN apt-get update && apt-get install -y \
  build-essential \
  bash \
  git \
  curl \
  unzip \
  && rm -rf /var/lib/apt/lists/*

# Install optional shells
RUN if [ "$USER_SHELL" = "fish" ]; then \
    apt-get update && apt-get install -y fish && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /home/${USERNAME}/.config/fish; \
  elif [ "$USER_SHELL" = "zsh" ]; then \
    apt-get update && apt-get install -y zsh && rm -rf /var/lib/apt/lists/*; \
  fi

# Create user
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi && \
  groupadd -g ${HOST_GID} ${USERNAME} && \
  useradd -u ${HOST_UID} -g ${HOST_GID} -m -s /usr/bin/${USER_SHELL} ${USERNAME} && \
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

USER ${USERNAME}

ENV SHELL=/usr/bin/${USER_SHELL}

# Set-up persisted directories
RUN mkdir -p /home/${USERNAME}/.container-cache && \
    mkdir -p /home/${USERNAME}/.container-local

# Redirect history to a persisted `.container-local` directory
# NOTE: the `fish` shell already handle all this more sanely following `XDG` directories standards
RUN echo "export HISTFILE=/home/${USERNAME}/.container-local/.bash_history" > /home/${USERNAME}/.container-overrides.bash && \
    echo "export HISTFILE=/home/${USERNAME}/.container-local/.zsh_history" > /home/${USERNAME}/.container-overrides.zsh && \
    printf "\n# Container overrides\n[ -f ~/.container-overrides.bash ] && source ~/.container-overrides.bash\n" >> /home/${USERNAME}/.bashrc && \
    if [ "$USER_SHELL" = "zsh" ]; then \
      printf "\n# Container overrides\n[ -f ~/.container-overrides.zsh ] && source ~/.container-overrides.zsh\n" >> /home/${USERNAME}/.zshrc; \
    fi

# Set various persistent caches locations through env
ENV XDG_CACHE_HOME=/home/${USERNAME}/.container-cache/cache \
    XDG_STATE_HOME=/home/${USERNAME}/.container-local/state \
    XDG_DATA_HOME=/home/${USERNAME}/.container-local/data

#############################################
FROM ubuntu-base AS ubuntu-tools

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG USERNAME=dev
ARG USER_SHELL=bash

# Additional packages outside the core base, separated by a space.
# Have to be in Ubuntu's default repository
ARG SUPPLEMENTARY_PACKAGES=""

# Configurable tool installation
ARG INSTALL_NEOVIM=true
ARG INSTALL_STARSHIP=true
ARG INSTALL_ATUIN=true
ARG INSTALL_MISE=true
ARG INSTALL_ZELLIJ=true
ARG INSTALL_NODE=latest
ARG INSTALL_RUST=none
ARG INSTALL_PYTHON=none
ARG INSTALL_GO=none
ARG ENABLE_WASM=false
ARG ENABLE_SUDO=false
ARG GIT_AUTHOR_NAME=""
ARG GIT_AUTHOR_EMAIL=""

USER root

# Set all the right envs to the persisted storages just to be sure
ENV _ZO_DATA_DIR=/home/${USERNAME}/.container-local/zoxide \
    STARSHIP_CACHE=/home/${USERNAME}/.container-local/starship \
    ATUIN_DB_PATH=/home/${USERNAME}/.container-local/atuin/history.db

# Install sudo and configure it (optional)
RUN if [ "$ENABLE_SUDO" = "true" ]; then \
    apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/* && \
    usermod -aG sudo ${USERNAME} && \
    echo "${USERNAME}:dev" | chpasswd; \
  fi

# Install packages the user listed as "supplementary"
RUN if [ -n "$SUPPLEMENTARY_PACKAGES" ]; then \
    apt-get update && apt-get install -y $SUPPLEMENTARY_PACKAGES && rm -rf /var/lib/apt/lists/*; \
  fi

# Install Neovim (optional)
RUN if [ "$INSTALL_NEOVIM" = "true" ]; then \
    curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz && \
    tar -C /opt -xzf nvim-linux-x86_64.tar.gz && \
    rm nvim-linux-x86_64.tar.gz && \
    ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim; \
  fi

# Install Zellij (optional)
RUN if [ "$INSTALL_ZELLIJ" = "true" ]; then \
    curl -LO https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz && \
    tar -C /opt -xzf zellij-x86_64-unknown-linux-musl.tar.gz && \
    rm zellij-x86_64-unknown-linux-musl.tar.gz && \
    ln -s /opt/zellij /usr/local/bin/zellij; \
  fi

# Install Starship (optional)
RUN if [ "$INSTALL_STARSHIP" = "true" ]; then \
    curl -sS https://starship.rs/install.sh | sh -s -- -y; \
  fi

RUN if [ "$ENABLE_WASM" = "true" ]; then \
    BINARYEN_VERSION=$(curl -s https://api.github.com/repos/WebAssembly/binaryen/releases/latest | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//') && \
    curl -L "https://github.com/WebAssembly/binaryen/releases/download/${BINARYEN_VERSION}/binaryen-${BINARYEN_VERSION}-x86_64-linux.tar.gz" -o binaryen.tar.gz && \
    tar -xzf binaryen.tar.gz && \
    mv binaryen-${BINARYEN_VERSION} /opt/binaryen && \
    ln -s /opt/binaryen/bin/* /usr/local/bin/ && \
    rm binaryen.tar.gz; \
  fi

USER ${USERNAME}

# Add tool initialization lines BEFORE copying user configs
# This ensures they're present if user doesn't provide custom configs

# Install `starship` (optional)
RUN if [ "$INSTALL_STARSHIP" = "true" ]; then \
    printf '\n# Initialize starship prompt\neval "$(starship init bash)"\n' >> /home/${USERNAME}/.bashrc && \
    if [ "$USER_SHELL" = "zsh" ]; then \
      printf '\n# Initialize starship prompt\neval "$(starship init zsh)"\n' >> /home/${USERNAME}/.zshrc; \
    elif [ "$USER_SHELL" = "fish" ]; then \
      printf '\n# Initialize starship prompt\nstarship init fish | source\n' >> /home/${USERNAME}/.config/fish/config.fish; \
    fi; \
  fi

# Install `atuin` (optional)
RUN if [ "$INSTALL_ATUIN" = "true" ]; then \
    curl --proto '=https' --tlsv1.2 -sSf https://setup.atuin.sh | bash && \
    printf "\n# Initialize atuin\neval \"\$(atuin init bash)\"\n" >> /home/${USERNAME}/.bashrc && \
    if [ "$USER_SHELL" = "zsh" ]; then \
      printf "\n# Initialize atuin\neval \"\$(atuin init zsh)\"\n" >> /home/${USERNAME}/.zshrc; \
    elif [ "$USER_SHELL" = "fish" ]; then \
      printf "\n# Initialize atuin prompt\natuin init fish | source\n" >> /home/${USERNAME}/.config/fish/config.fish; \
    fi; \
    if [ "$USER_SHELL" != "zsh" ]; then \
      # atuin weirdly seems to create a default `.zshrc` with its setup inside.
      # We don't need this as a tool could think that zsh is relied on or want to update
      # that file if it exists, complexifying things for nothing.
      rm -f /home/${USERNAME}/.zshrc; \
    fi; \
  fi

# Install `mise` + languages (optional)
RUN if [ "$INSTALL_MISE" = "true" ]; then \
    curl https://mise.jdx.dev/install.sh | sh && \
    printf "\n# Initialize mise\neval \"\$(mise activate bash)\"\n" >> /home/${USERNAME}/.bashrc && \
    if [ "$USER_SHELL" = "fish" ]; then \
      printf "\n# Initialize mise\nmise activate fish | source\n" >> /home/${USERNAME}/.config/fish/config.fish; \
    elif [ "$USER_SHELL" = "zsh" ]; then \
      printf "\n# Initialize mise\neval \"\$(mise activate zsh)\"\n" >> /home/${USERNAME}/.zshrc; \
    fi; \
    if [ -n "$INSTALL_NODE" ] && [ "$INSTALL_NODE" != "none" ]; then \
      export PATH="/home/${USERNAME}/.local/bin:$PATH" && \
      mise use -g node@${INSTALL_NODE}; \
    fi; \
    if [ -n "$INSTALL_RUST" ] && [ "$INSTALL_RUST" != "none" ]; then \
      export PATH="/home/${USERNAME}/.local/bin:$PATH" && mise use -g rust@${INSTALL_RUST}; \
    fi; \
    if [ -n "$INSTALL_PYTHON" ] && [ "$INSTALL_PYTHON" != "none" ]; then \
      export PATH="/home/${USERNAME}/.local/bin:$PATH" && mise use -g python@${INSTALL_PYTHON}; \
    fi; \
    if [ -n "$INSTALL_GO" ] && [ "$INSTALL_GO" != "none" ]; then \
      export PATH="/home/${USERNAME}/.local/bin:$PATH" && mise use -g go@${INSTALL_GO}; \
    fi; \
  fi

USER root

# If `mise` is not installed, install languages through Ubuntu's repositories
RUN if [ "$INSTALL_MISE" != "true" ]; then \
    # Just install nodejs and npm from Ubuntu's repositories
    if [ -n "$INSTALL_NODE" ] && [ "$INSTALL_NODE" != "none" ]; then \
      if [ "$INSTALL_NODE" != "latest" ]; then \
        echo "\033[1;33mWarning: Using Ubuntu's nodejs as \"INSTALL_MISE\" is not set to \"true\". NODE_VERSION=${INSTALL_NODE} ignored.\033[0m" >&2; \
      fi; \
      apt-get update && apt-get install -y \
        nodejs \
        npm \
        && rm -rf /var/lib/apt/lists/*; \
    fi; \
    if [ -n "$INSTALL_RUST" ] && [ "$INSTALL_RUST" != "none" ]; then \
      if [ "$INSTALL_RUST" != "latest" ]; then \
        echo "\033[1;33mWarning: Using Ubuntu's rust as \"INSTALL_MISE\" is not set to \"true\". RUST_VERSION=${INSTALL_RUST} ignored.\033[0m" >&2; \
      fi; \
      su - ${USERNAME} -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
        . /home/${USERNAME}/.cargo/env && \
        rustup default stable"; \
    fi; \
    if [ -n "$INSTALL_PYTHON" ] && [ "$INSTALL_PYTHON" != "none" ]; then \
      if [ "$INSTALL_PYTHON" != "latest" ]; then \
        echo "\033[1;33mWarning: Using Ubuntu's python as \"INSTALL_MISE\" is not set to \"true\". PYTHON_VERSION=${INSTALL_PYTHON} ignored.\033[0m" >&2; \
      fi; \
      apt-get update && apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        && rm -rf /var/lib/apt/lists/*; \
      # Set up python3 as default python
      update-alternatives --install /usr/bin/python python /usr/bin/python3 1; \
    fi; \
    if [ -n "$INSTALL_GO" ] && [ "$INSTALL_GO" != "none" ]; then \
      if [ "$INSTALL_GO" != "latest" ]; then \
        echo "\033[1;33mWarning: Using Ubuntu's go as \"INSTALL_MISE\" is not set to \"true\". GO_VERSION=${INSTALL_GO} ignored.\033[0m" >&2; \
      fi; \
      apt-get update && apt-get install -y \
        golang-go \
        && rm -rf /var/lib/apt/lists/*; \
    fi; \
  fi

USER ${USERNAME}

# Set-up language envs
RUN if [ -n "$INSTALL_NODE" ] && [ "$INSTALL_NODE" != "none" ]; then \
      # Setup dirs and add yarn globally, just in case
      if [ "$INSTALL_MISE" != "true" ]; then \
        npm config set prefix "/home/${USERNAME}/.local" && \
        npm config set cache /home/${USERNAME}/.container-cache/.npm && \
        npm install -g yarn && \
        yarn config set cacheFolder /home/${USERNAME}/.container-cache/.yarn; \
      else \
        mise exec -- npm config set prefix "/home/${USERNAME}/.local" && \
        mise exec -- npm config set cache /home/${USERNAME}/.container-cache/.npm && \
        mise exec -- npm install -g yarn && \
        mise exec -- yarn config set cacheFolder /home/${USERNAME}/.container-cache/.yarn; \
      fi; \
    fi; \
    if [ -n "$INSTALL_RUST" ] && [ "$INSTALL_RUST" != "none" ]; then \
      if [ "$ENABLE_WASM" = "true" ]; then \
        if [ "$INSTALL_MISE" != "true" ]; then \
          rustup target add wasm32-unknown-unknown; \
        else \
          export PATH="/home/${USERNAME}/.local/bin:$PATH" && \
          mise exec -- rustup target add wasm32-unknown-unknown; \
        fi; \
      fi; \
      echo '. $HOME/.cargo/env' >> /home/${USERNAME}/.bashrc; \
      if [ "$USER_SHELL" = "zsh" ]; then \
        echo '. $HOME/.cargo/env' >> /home/${USERNAME}/.zshrc; \
      elif [ "$USER_SHELL" = "fish" ]; then \
        echo 'set -gx PATH $HOME/.cargo/bin $PATH' >> /home/${USERNAME}/.config/fish/config.fish; \
      fi; \
    fi; \
    if [ -n "$INSTALL_PYTHON" ] && [ "$INSTALL_PYTHON" != "none" ]; then \
      mkdir -p /home/${USERNAME}/.container-cache/pip; \
      echo 'export PIP_CACHE_DIR="$HOME/.container-cache/pip"' >> /home/${USERNAME}/.bashrc; \
      if [ "$USER_SHELL" = "zsh" ]; then \
        echo 'export PIP_CACHE_DIR="$HOME/.container-cache/pip"' >> /home/${USERNAME}/.zshrc; \
      elif [ "$USER_SHELL" = "fish" ]; then \
        echo 'set -gx PIP_CACHE_DIR $HOME/.container-cache/pip' >> /home/${USERNAME}/.config/fish/config.fish; \
      fi; \
    fi; \
    if [ -n "$INSTALL_GO" ] && [ "$INSTALL_GO" != "none" ]; then \
      # Set up Go paths for persistence
      mkdir -p /home/${USERNAME}/.container-local/gopath /home/${USERNAME}/.container-cache/go/mod; \
      echo 'export GOPATH="$HOME/.container-local/gopath"' >> /home/${USERNAME}/.bashrc; \
      echo 'export GOMODCACHE="$HOME/.container-cache/go/mod"' >> /home/${USERNAME}/.bashrc; \
      echo 'export PATH="$GOPATH/bin:$PATH"' >> /home/${USERNAME}/.bashrc; \
      if [ "$USER_SHELL" = "zsh" ]; then \
          echo 'export GOPATH="$HOME/.container-local/gopath"' >> /home/${USERNAME}/.zshrc; \
          echo 'export GOMODCACHE="$HOME/.container-cache/go/mod"' >> /home/${USERNAME}/.zshrc; \
          echo 'export PATH="$GOPATH/bin:$PATH"' >> /home/${USERNAME}/.zshrc; \
      elif [ "$USER_SHELL" = "fish" ]; then \
          echo 'set -gx GOPATH $HOME/.container-local/gopath' >> /home/${USERNAME}/.config/fish/config.fish; \
          echo 'set -gx GOMODCACHE $HOME/.container-cache/go/mod' >> /home/${USERNAME}/.config/fish/config.fish; \
          echo 'set -gx PATH $GOPATH/bin $PATH' >> /home/${USERNAME}/.config/fish/config.fish; \
      fi; \
    fi

# That one should just be default everywhere
# Done before file copying to ensure that it can be overwritten
RUN git config --global merge.conflictstyle zdiff3

# Copy config files (may overwrite shell configs with tool init lines)
RUN --mount=type=bind,source=configs,target=/tmp/configs \
  if [ -d /tmp/configs ] && [ "$(ls -A /tmp/configs 2>/dev/null)" ]; then \
    cp -r /tmp/configs/. /home/${USERNAME}/; \
  fi

# Ensure HISTFILE override is still sourced after config copy
# This guarantees history persistence even if user configs were copied
RUN if [ -f /home/${USERNAME}/.bashrc ] && ! grep -qF 'container-overrides.bash' /home/${USERNAME}/.bashrc; then \
    printf "\n# Container overrides\n[ -f ~/.container-overrides.bash ] && source ~/.container-overrides.bash\n" >> /home/${USERNAME}/.bashrc; \
  fi

RUN if [ "$USER_SHELL" = "zsh" ] && [ -f /home/${USERNAME}/.zshrc ] && ! grep -qF 'container-overrides.zsh' /home/${USERNAME}/.zshrc; then \
    printf "\n# Container overrides\n[ -f ~/.container-overrides.zsh ] && source ~/.container-overrides.zsh\n" >> /home/${USERNAME}/.zshrc; \
  fi

# Pre-install nvim plugins if neovim is installed with `lazy.nvim` and config
# exists, for convenience
RUN if [ "$INSTALL_NEOVIM" = "true" ] && [ -d /home/${USERNAME}/.config/nvim ]; then \
      nvim --headless "+Lazy! sync" +qa || true; \
  fi

# Set git name/e-mail according to what has been configured
# **AFTER** the copy to ensure we overwrite what has potentially been copied
RUN if [ -n "$GIT_AUTHOR_NAME" ]; then \
    git config --global user.name "$GIT_AUTHOR_NAME"; \
  fi

RUN if [ -n "$GIT_AUTHOR_EMAIL" ]; then \
    git config --global user.email "$GIT_AUTHOR_EMAIL"; \
  fi

#############################################
FROM ubuntu-tools AS ubuntu-projects

ARG USERNAME=dev

USER ${USERNAME}

# Set-up projects directory
RUN mkdir -p /home/${USERNAME}/projects

WORKDIR /home/${USERNAME}/projects

CMD $SHELL
