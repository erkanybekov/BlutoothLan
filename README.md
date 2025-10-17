# BlutoothLan

Мини-проект на Swift, реализующий обмен данными между устройствами через Bluetooth (BLE) в стиле локальной сети.

BlutootthLan.xcodeproj
└── BlutootthLan
    ├── Assets.xcassets
    ├── Models
    ├── Presentation
    ├── Utils
    ├── ViewModels
    ├── BlutootthLanApp.swift
    ├── Info.plist
    └── README.md

---

## 🏗 AVR - Approximate Visual Representation

```text
+-----------------+        +-----------------+
| Device A (App)  |        | Device B (App)  |
+-----------------+        +-----------------+
|                 |        |                 |
|  Bluetooth BLE   | <———>  |  Bluetooth BLE   |
|  — Advertising / |        |  — Scanning /    |
|    Peripheral    |        |    Central       |
|  — GATT Server   |        |  — GATT Client   |
|  — Service /     |        |  — Read / Write  |
|    Characteristics|      |    / Notify      |
|                 |        |                 |
+-----------------+        +-----------------+

