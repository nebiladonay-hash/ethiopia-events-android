plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val tiqetSupabaseUrl = providers.environmentVariable("SUPABASE_URL")
    .orElse("https://ebrrdmxyoioefoprtict.supabase.co").get()
val tiqetSupabaseKey = providers.environmentVariable("SUPABASE_ANON_KEY")
    .orElse("sb_publishable_8wcj3P6I709KpvRA0LHmNA_QoTYFj8h").get()

android {
    namespace = "et.tiqet.control"
    compileSdk = 36

    defaultConfig {
        applicationId = "et.tiqet.control"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "SUPABASE_URL", "\"$tiqetSupabaseUrl\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"$tiqetSupabaseKey\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
