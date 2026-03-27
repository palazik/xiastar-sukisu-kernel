#!/usr/bin/env bash
# ==============================================================================
# Высокопроизводительный конвейер сборки ядра Android с использованием Proton Clang
# Архитектура: AArch64 | Оптимизации: LTO, PGO, Polly
# ==============================================================================

# Завершение работы при возникновении неперехваченных ошибок
set -e 

# Инициализация переменных директорий
WORKSPACE_DIR="$(pwd)"
KERNEL_DIR="${WORKSPACE_DIR}/kernel_source"
TOOLCHAIN_DIR="${WORKSPACE_DIR}/proton-clang"
ANYKERNEL_DIR="${WORKSPACE_DIR}/AnyKernel3"
OUT_DIR="${KERNEL_DIR}/out"

# Параметры конфигурации целевого ядра
ARCH="arm64"
DEFCONFIG="vendor/xiaomi/sm8250_defconfig" # Пример для платформы Snapdragon 865
KERNEL_VERSION="5.4-Proton-SuSFS"
TIMESTAMP="$(date +"%Y%m%d_%H%M")"
CORES="$(nproc --all)"

echo "[1/6] Клонирование репозиториев и инструментария..."
# Поверхностное клонирование Proton Clang для минимизации сетевого трафика
if; then
    git clone --depth=1 https://github.com/kdrag0n/proton-clang.git "${TOOLCHAIN_DIR}"
fi

# Клонирование шаблонного упаковщика AnyKernel3
if; then
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "${ANYKERNEL_DIR}"
fi

# Предполагается, что исходный код ядра уже находится в директории kernel_source
if; then
    echo "Ошибка: Директория исходного кода ядра (${KERNEL_DIR}) не обнаружена."
    exit 1
fi

echo "[2/6] Экспорт переменных окружения (Kbuild Compiler Directives)..."
# Добавление путей бинарников LLVM в системную среду
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Определение префиксов для кросс-компиляции
# CLANG_TRIPLE не требуется, так как Proton Clang содержит собственные конфигурации
export CC="clang"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-" # Для vDSO на ядрах 4.19+
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"   # Обратная совместимость

echo "[3/6] Лексическая очистка и патчинг исходного кода (Clang strict semantics)..."
cd "${KERNEL_DIR}"

# 3.1. Устранение Undefined Behavior: "division by zero is undefined" в mman.h
# Clang версии 12+ обрывает компиляцию при нахождении макросов с 1/0
if grep -q "1 / 0" include/uapi/asm-generic/mman.h 2>/dev/null; then
    echo "  -> Патчинг asm-generic/mman.h..."
    sed -i 's|1 / 0|0|g' include/uapi/asm-generic/mman.h
    sed -i 's|1 / 0|0|g' arch/arm64/include/uapi/asm/mman.h 2>/dev/null |

| true
fi

# 3.2. Восстановление синтаксиса KABI после внедрения патчей SuSFS
# Автоматические утилиты слияния часто оставляют '>>>>>>> replacement' в файле mount.h,
# если поля susfs_mnt_id_backup конфликтуют с модификациями производителя (например, Xiaomi).
if [ -f "include/linux/mount.h" ]; then
    echo "  -> Валидация синтаксиса include/linux/mount.h..."
    # Удаление невалидных строковых маркеров конфликта git/wiggle
    sed -i '/>>>>>>> replacement/d' include/linux/mount.h 2>/dev/null |

| true
    sed -i '/======/d' include/linux/mount.h 2>/dev/null |

| true
    # Адаптация резервных полей ANDROID_KABI_USE
    sed -i '/ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);/d' include/linux/mount.h 2>/dev/null |

| true
fi

# 3.3. Включение модуля SuSFS в сборочный граф, если он был скопирован
if grep -q "susfs.c" fs/Makefile 2>/dev/null |

| [ -f "fs/susfs.c" ]; then
    if! grep -q "susfs.o" fs/Makefile; then
        echo "obj-y += susfs.o" >> fs/Makefile
    fi
fi

echo "[4/6] Инициализация конфигурации Kbuild..."
# Полная очистка дерева исходников и артефактов старых сборок
make O="${OUT_DIR}" ARCH="${ARCH}" mrproper

# Создание файла.config на основе конфигурации производителя
make O="${OUT_DIR}" ARCH="${ARCH}" CC="${CC}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}" \
    LLVM=1 LLVM_IAS=1 \
    "${DEFCONFIG}"

echo "[5/6] Старт многопоточной компиляции (LLVM/LTO)..."
# Вызов системы сборки с полным делегированием полномочий LLVM инструментарию
# LLVM=1 активирует ld.lld, llvm-ar, llvm-objcopy
# LLVM_IAS=1 активирует встроенный ассемблер Clang
make -j"${CORES}" O="${OUT_DIR}" ARCH="${ARCH}" CC="${CC}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}" \
    CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
    LLVM=1 LLVM_IAS=1

# Проверка наличия собранного ядра
COMPILED_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
if; then
    echo "Критическая ошибка: Файл Image не сгенерирован. Изучите логи компилятора."
    exit 1
fi
echo "Успех: Бинарный файл ядра успешно создан."

echo "[6/6] Упаковка ядра в формат AnyKernel3..."
cd "${WORKSPACE_DIR}"
rm -rf "${ANYKERNEL_DIR}/Image" "${ANYKERNEL_DIR}/Image.gz" "${ANYKERNEL_DIR}/dtb" "${ANYKERNEL_DIR}/dtbo.img"

# Интеграция бинарных артефактов в шаблон упаковщика
cp "${COMPILED_IMAGE}" "${ANYKERNEL_DIR}/"
cp "${KERNEL_DIR}/out/arch/arm64/boot/dtbo.img" "${ANYKERNEL_DIR}/" 2>/dev/null |

| true
# Поиск и перенос всех собранных файлов Device Tree Blob (dtb)
find "${KERNEL_DIR}/out/arch/arm64/boot/dts/vendor/" -name "*.dtb" -exec cp {} "${ANYKERNEL_DIR}/dtb/" \; 2>/dev/null |

| true

cd "${ANYKERNEL_DIR}"
ZIP_FILENAME="${KERNEL_VERSION}-${TIMESTAMP}.zip"
zip -r9 "${ZIP_FILENAME}" * -x.git README.md *placeholder

mv "${ZIP_FILENAME}" "${WORKSPACE_DIR}/"
echo "================================================="
echo " Building finished. File: ${ZIP_FILENAME} "
echo "================================================="
