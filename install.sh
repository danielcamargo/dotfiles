SOURCE="https://github.com/danielcamargo/dotfiles"
TARGET="$HOME/.dotfiles"

OS="unknown"

# Check if this is linux, mac or windows
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  echo "Linux detected"
  OS="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
  echo "MacOS detected"
  OS="mac"
elif [[ "$OSTYPE" == "cygwin" ]]; then
  echo "Cygwin detected"
  OS="windows"
elif [[ "$OSTYPE" == "msys" ]]; then
  echo "Mingw detected"
  OS="windows"
elif [[ "$OSTYPE" == "win32" ]]; then
  echo "Windows detected"
  OS="windows"
else
  echo "Unsupported OS"
fi

# If OS is uknown, exit
if [ "$OS" == "unknown" ]; then
  exit 1
fi

# check if $HOME/.dotfiles exists, if so, git pull, otherwise clone
if [ -d "$TARGET" ]; then
  cd "$TARGET" || exit
  echo "Updating existing dotfiles repository..."
  # reset any local changes
  git clean -fd
  git reset --hard HEAD
  git pull
else
  echo "Cloning dotfiles repository..."
  git clone $SOURCE $TARGET
fi

## ZSH Configuration
# Create or replace the symlink for .zshrc
echo "Creating symlink for .zshrc/.bashrc ($OS)"

# if windows, we will create a .bashrc instead of .zshrc
if [ "$OS" == "windows" ]; then
  ln -sf $TARGET/system/.bashrc_$OS $HOME/.bashrc
else
  ln -sf $TARGET/system/.zshrc_$OS $HOME/.zshrc
fi

## Git Configuration
# Create or replace the symlink for .gitconfig
ln -sf $TARGET/git/.gitconfig $HOME/.gitconfig
ln -sf $TARGET/git/.gitignore_global $HOME/.gitignore_global

# Define an array of folder names
folders=("Personal" "Ensign" "Church" "PracticeFront" "VCom")

# Ensure the base directory exists
mkdir -p "$HOME/Projects"

# Loop through the array and create folders if they don't exist
for folder in "${folders[@]}"; do
  mkdir -p "$HOME/Projects/$folder"
  FOLDER_LOWERCASE=$(echo "$folder" | tr '[:upper:]' '[:lower:]')
  # add the .gitconfig_<folder> (lowercase) file as a symlink
  ln -sf "$TARGET/git/.gitconfig_$FOLDER_LOWERCASE" "$HOME/Projects/$folder/.gitconfig"
done
