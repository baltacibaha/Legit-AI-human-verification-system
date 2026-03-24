# LEGIT — Proof of Presence Platform

Yapay zekanın ürettiği içeriklerin interneti kapladığı bir dönemde, bir içeriğin gerçekten o anda, o kişi tarafından üretildiğini kriptografik olarak kanıtlayan mobil platform.

---

## Proje Yapısı

```
legit-project/
├── swift/                          # iOS Uygulaması (Xcode'a ekle)
│   ├── LegitSensorCore.swift       # GPS + IMU + SHA-256 + P-256 imzalama
│   ├── LegitCameraView.swift       # AVFoundation kamera + shutter senkronizasyonu
│   ├── LegitPassportView.swift     # SwiftUI skor halkaları + pasaport ekranı
│   ├── LegitAPIClient.swift        # URLSession API istemcisi (submit/verify)
│   ├── LegitNavigationStore.swift  # NavigationPath durum yönetimi
│   └── LegitRootView.swift         # App entry point + tam navigasyon akışı
│
├── php/                            # Backend (sunucuya yükle)
│   ├── LegitAPIClient.php          # REST API controller (JWT, nonce, routing)
│   └── ScoringEngine.php           # 6 boyutlu skor algoritması
│
├── sql/
│   └── legit_schema.sql            # MySQL 8.0+ şema, view, stored procedure
│
└── legit-blockchain/               # Node.js Mikroservis
    ├── index.js                    # Ana orchestrator: polling, retry, webhook
    ├── ipfsService.js              # Pinata SDK wrapper (IPFS yükleme)
    ├── easService.js               # EAS SDK + ethers.js (on-chain attestation)
    ├── package.json
    ├── ecosystem.config.js         # PM2 production konfigürasyonu
    ├── Dockerfile                  # Alpine, non-root kullanıcı, dumb-init
    ├── .env.example                # Tüm environment variable'lar
    ├── scripts/
    │   └── deploySchema.js         # Tek seferlik EAS şema deployment
    └── deploy/
        └── aws-setup.sh            # EC2 bootstrap + Docker deployment scripti
```

---

## Xcode Kurulum Adımları

### 1. Yeni Proje Oluştur
```
File → New → Project → iOS → App
Product Name: LEGIT
Interface: SwiftUI
Language: Swift
```

### 2. Varsayılan Dosyaları Sil
```
ContentView.swift   → Delete → Move to Trash
LEGITApp.swift      → Delete → Move to Trash
```

### 3. Swift Dosyalarını Ekle
`swift/` klasöründeki 6 dosyayı Xcode'a sürükle:
- Copy items if needed ✓
- Add to target: LEGIT ✓

### 4. Info.plist İzinleri
```xml
NSCameraUsageDescription
→ LEGIT içerik doğrulaması için kamera gereklidir.

NSLocationWhenInUseUsageDescription
→ Proof of Presence için konum gereklidir.

NSPhotoLibraryAddUsageDescription
→ Çekilen fotoğrafı kaydetmek için izin gereklidir.
```

### 5. LegitConfig.plist Oluştur
```
File → New → File → Property List → LegitConfig.plist

APIBaseURL  →  https://api.senin-domain.com
JWTToken    →  backend'den üretilen JWT token
```
> Geliştirme aşamasında `APIBaseURL` olmadan da çalışır — dummy config otomatik yüklenir.

### 6. Capabilities
```
Project → Target → Signing & Capabilities → + Capability
→ Keychain Sharing ekle
→ Keychain Groups: com.senin.legit
```

### 7. Build
```
Cmd + B  →  Build
Cmd + R  →  Çalıştır
```

---

## Backend Kurulum

### Veritabanı
```bash
mysql -u root -p < sql/legit_schema.sql
```

### PHP Environment Variables
```
LEGIT_JWT_SECRET=gizli_jwt_anahtari
DB_HOST=127.0.0.1
DB_NAME=legit_db
DB_USER=legit_app
DB_PASS=sifre
INTERNAL_SERVICE_TOKEN=guvenli_token
LEGIT_NODE_URL=http://127.0.0.1:3001
```

---

## Blockchain Mikroservis Kurulum

```bash
cd legit-blockchain
cp .env.example .env
# .env dosyasını doldur

npm install
node scripts/deploySchema.js    # Bir kez çalıştır — EAS şemasını deploy eder
npm start
```

### AWS EC2 ile Docker Deployment
```bash
export LEGIT_SECRET_ARN=arn:aws:secretsmanager:REGION:ACCOUNT:secret:legit/prod
sudo bash legit-blockchain/deploy/aws-setup.sh
```

---

## Environment Variables Özeti

| Değişken | Servis | Açıklama |
|----------|--------|----------|
| `LEGIT_JWT_SECRET` | PHP | HMAC-SHA256 JWT imzalama anahtarı |
| `DB_HOST/NAME/USER/PASS` | PHP + Node | MySQL bağlantısı |
| `PINATA_JWT` | Node | Pinata API JWT (IPFS) |
| `EAS_PRIVATE_KEY` | Node | Ethereum cüzdan private key |
| `EAS_RPC_URL` | Node | JSON-RPC endpoint (Alchemy/Infura) |
| `EAS_SCHEMA_UID` | Node | deploySchema.js'den dönen UID |
| `INTERNAL_SERVICE_TOKEN` | PHP + Node | Servisler arası güvenlik tokeni |
| `PHP_WEBHOOK_URL` | Node | PHP webhook endpoint |

---

## Güvenlik Mimarisi

- **JWT**: Her istekte server-side doğrulama
- **Nonce + Timestamp**: Replay attack koruması (5 dakika pencere)
- **ECDSA P-256**: İmzalar server-side cihaz anahtarına göre doğrulanır
- **Zero-Knowledge Proof**: Kimlik doğrulama — kişisel veri saklanmaz
- **IP Hash**: SHA-256 — ham IP hiçbir zaman saklanmaz
- **Docker**: Non-root kullanıcı (UID 1001), cap-drop ALL
- **AWS Secrets Manager**: Production secret yönetimi

---

## 6 Boyutlu LEGIT Skoru

| Boyut | Ağırlık | Açıklama |
|-------|---------|----------|
| Identity | %25 | ZK-proof kimlik doğrulama seviyesi |
| Consistency | %15 | Zaman/konum/hareket tutarlılığı |
| Presence | %20 | GPS doğruluğu ve tazeliği |
| AI Detection | %20 | İnsan üretimi olasılığı (ters) |
| History | %10 | Kullanıcının geçmiş güven puanı |
| Consensus | %10 | Topluluk oyları ve doğrulamaları |
