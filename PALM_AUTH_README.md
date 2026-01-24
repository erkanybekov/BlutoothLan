# Palm Authentication Integration

## Обзор

Интеграция системы аутентификации по ладони в приложение BlutoothLan с использованием Vision framework от Apple для детекции рук.

## Компоненты

### 1. Модели данных (`PalmModels.swift`)

- **PalmLandmark**: Структура для хранения координат точек руки (x, y, z)
- **PalmDetectionState**: Состояния процесса детекции (idle, detecting, success, error)
- **PalmVerificationRequest**: Запрос на верификацию с landmarks и метаданными
- **PalmVerificationResponse**: Ответ сервера верификации
- **PalmVerificationState**: Состояния процесса верификации

### 2. Сервис детекции (`HandDetectionService.swift`)

Использует:
- **AVFoundation** для работы с камерой
- **Vision framework** для детекции руки (`VNDetectHumanHandPoseRequest`)

Функционал:
- Запуск/остановка камеры
- Детекция до 21 точки руки в реальном времени
- Расчет уверенности (confidence) детекции
- Проверка разрешений камеры

### 3. ViewModel (`PalmAuthViewModel.swift`)

Управляет:
- Состоянием детекции
- Захватом landmarks
- Верификацией через API
- Обработкой разрешений

### 4. UI (`PalmAuthView.swift`)

Интерфейс включает:
- Превью камеры в реальном времени
- Рамку для позиционирования руки
- Индикаторы состояния детекции
- Визуализацию landmarks
- Кнопки захвата и верификации

### 5. Визуализация (`HandLandmarkOverlay.swift`)

- Отображение 21 точки руки
- Соединения между точками (скелет руки)
- Информационная панель с confidence
- Цветовая индикация качества детекции

## Использование

### Запуск аутентификации

В главном экране приложения добавлена кнопка с иконкой руки в toolbar:

```swift
Button {
    activeSheet = .palmAuth
} label: {
    Image(systemName: "hand.raised.fill")
}
```

### Процесс аутентификации

1. **Запуск**: Нажмите на иконку руки в toolbar
2. **Разрешение**: Предоставьте доступ к камере (если требуется)
3. **Позиционирование**: Поместите ладонь в рамку на экране
4. **Детекция**: Держите руку неподвижно, пока система не обнаружит все точки
5. **Захват**: Когда confidence > 70%, нажмите "Capture"
6. **Верификация**: Нажмите "Verify" для проверки

### Индикаторы состояния

- 🔴 **Серый**: Готов к детекции
- 🟡 **Желтый**: Идет детекция
- 🟢 **Зеленый**: Рука обнаружена успешно
- 🔴 **Красный**: Ошибка

## Интеграция с API

### Отправка запроса верификации

```swift
let request = PalmVerificationRequest(
    landmarks: capturedLandmarks,
    accuracy: Double(confidence),
    userId: "user123"
)

let response = try await viewModel.sendVerificationRequest(
    request, 
    to: "https://your-api.com/verify"
)
```

### Формат запроса

```json
{
  "landmarks": [
    {"x": 0.5, "y": 0.3, "z": 0.0},
    ...
  ],
  "accuracy": 0.85,
  "timestamp": 1706112000000,
  "userId": "user123"
}
```

### Формат ответа

```json
{
  "verified": true,
  "confidence": 0.92,
  "message": "Palm verified successfully",
  "timestamp": 1706112001000,
  "userId": "user123"
}
```

## Требования

### Разрешения (Info.plist)

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs access to the camera for palm authentication and hand detection.</string>
```

### Минимальные требования

- iOS 14.0+
- Камера (фронтальная)
- Vision framework

## Архитектура

```
┌─────────────────┐
│  PalmAuthView   │ (UI Layer)
└────────┬────────┘
         │
┌────────▼────────────┐
│ PalmAuthViewModel   │ (Business Logic)
└────────┬────────────┘
         │
┌────────▼──────────────┐
│ HandDetectionService  │ (Detection)
└───────────────────────┘
         │
    ┌────┴────┐
    │         │
┌───▼───┐ ┌──▼──────┐
│ Vision│ │AVFoundation│
└───────┘ └──────────┘
```

## Настройка детекции

### Минимальное количество точек

```swift
if landmarks.count >= 15 { // Минимум для валидной руки
    self?.detectionState = .success(landmarks: landmarks, confidence: avgConfidence)
}
```

### Порог confidence для захвата

```swift
private var canCapture: Bool {
    if case .success(_, let confidence) = viewModel.detectionState {
        return confidence > 0.7 // 70% уверенности
    }
    return false
}
```

## Расширенные возможности

### Добавление биометрической аутентификации

```swift
import LocalAuthentication

func authenticateWithBiometrics() {
    let context = LAContext()
    var error: NSError?
    
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, 
                              localizedReason: "Verify your identity") { success, error in
            // Handle result
        }
    }
}
```

### Сохранение landmarks локально

```swift
func saveLandmarksToKeychain(_ landmarks: [PalmLandmark]) {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(landmarks) {
        // Save to Keychain
    }
}
```

## Troubleshooting

### Камера не запускается

1. Проверьте разрешения в Settings > Privacy > Camera
2. Убедитесь что `NSCameraUsageDescription` добавлен в Info.plist
3. Перезапустите приложение

### Низкая точность детекции

1. Убедитесь в хорошем освещении
2. Держите руку ближе к камере
3. Избегайте сложного фона
4. Держите руку неподвижно

### Детекция не работает

1. Проверьте что используется фронтальная камера
2. Убедитесь что рука полностью в кадре
3. Попробуйте изменить угол руки

## Будущие улучшения

- [ ] Интеграция с MediaPipe для более точной детекции
- [ ] Поддержка обеих рук
- [ ] 3D координаты (z-axis)
- [ ] Машинное обучение для распознавания конкретных пользователей
- [ ] Offline верификация
- [ ] История аутентификаций
- [ ] Настройки чувствительности детекции

## Лицензия

Часть проекта BlutoothLan
