package et.events.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import et.events.mobile.backend.TiqetApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val AuthRed = Color(0xFFB82035)
private val AuthIvory = Color(0xFFF7F1E7)
private val AuthInk = Color(0xFF2B2020)
private val AuthMuted = Color(0xFF8C7771)

@Composable
fun TiqetAuthScreen(
    api: TiqetApi,
    role: String,
    onAuthenticated: () -> Unit,
    onBack: () -> Unit
) {
    var isSignUp by remember { mutableStateOf(false) }
    var fullName by remember { mutableStateOf("") }
    var phone by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier.fillMaxSize().background(AuthIvory).padding(horizontal = 24.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.Center
    ) {
        Text("TIQET", color = AuthRed, fontSize = 14.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 3.sp)
        Spacer(Modifier.height(28.dp))
        Text(if (isSignUp) "Create your account" else "Welcome back", color = AuthInk, fontSize = 29.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(7.dp))
        Text(
            if (role == "buyer") "Discover events and keep your tickets in one place."
            else "Create an organiser account. Publishing requires verification.",
            color = AuthMuted, fontSize = 13.sp, lineHeight = 19.sp
        )
        Spacer(Modifier.height(23.dp))

        if (!api.isConfigured()) {
            Text(
                "The Tiqet backend is not connected yet. Configure SUPABASE_URL and SUPABASE_ANON_KEY in the repository's GitHub Actions variables, then rebuild the APK.",
                color = AuthRed, fontSize = 13.sp, lineHeight = 19.sp
            )
            Spacer(Modifier.height(18.dp))
            AuthButton("Back", enabled = true, onClick = onBack)
            return@Column
        }

        if (isSignUp) {
            AuthField("Full name", fullName, { fullName = it })
            Spacer(Modifier.height(10.dp))
            AuthField("Phone number (+251…)", phone, { phone = it }, keyboardType = KeyboardType.Phone)
            Spacer(Modifier.height(10.dp))
        }
        AuthField("Email address", email, { email = it }, keyboardType = KeyboardType.Email)
        Spacer(Modifier.height(10.dp))
        AuthField("Password", password, { password = it }, password = true)
        Spacer(Modifier.height(17.dp))

        AuthButton(
            text = if (busy) "Please wait…" else if (isSignUp) "Create account" else "Sign in",
            enabled = !busy && email.isNotBlank() && password.length >= 6 && (!isSignUp || (fullName.isNotBlank() && phone.isNotBlank())),
            onClick = {
                error = ""
                notice = ""
                busy = true
                scope.launch {
                    try {
                        val session = withContext(Dispatchers.IO) {
                            if (isSignUp) api.signUp(email, password, fullName, phone) else api.signIn(email, password)
                        }
                        if (session != null) onAuthenticated()
                        else notice = "Account created. Open the confirmation email on this phone. The link should return you to Tiqet automatically."
                    } catch (exception: Exception) {
                        error = exception.message ?: "Authentication failed."
                    } finally { busy = false }
                }
            }
        )
        if (error.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            Text(error, color = AuthRed, fontSize = 12.sp, lineHeight = 17.sp)
        }
        if (notice.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            Text(notice, color = AuthInk, fontSize = 12.sp, lineHeight = 17.sp)
        }
        Spacer(Modifier.height(17.dp))
        Button(
            onClick = { isSignUp = !isSignUp; error = ""; notice = "" },
            modifier = Modifier.fillMaxWidth().height(48.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = AuthRed)
        ) {
            Text(if (isSignUp) "Already have an account? Sign in" else "New to Tiqet? Create an account", fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(5.dp))
        Button(
            onClick = onBack,
            modifier = Modifier.fillMaxWidth().height(44.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = AuthMuted)
        ) { Text("Change account type") }
    }
}

@Composable
private fun AuthField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType = KeyboardType.Text,
    password: Boolean = false
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None
    )
}

@Composable
private fun AuthButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().height(51.dp),
        shape = RoundedCornerShape(13.dp),
        colors = ButtonDefaults.buttonColors(containerColor = AuthRed, contentColor = AuthIvory)
    ) { Text(text, fontWeight = FontWeight.Bold) }
}
