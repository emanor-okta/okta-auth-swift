/*
 * Copyright (c) 2019, Okta, Inc. and/or its affiliates. All rights reserved.
 * The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
 *
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *
 * See the License for the specific language governing permissions and limitations under the License.
 */

import UIKit
import OktaAuthSdk
import OktaOAuth2

let oktaDomain = "{domain}.okta.com"
class ViewController: UIViewController {

    var currentStatus: OktaAuthStatus?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.updateStatus(status: nil)
    }

    @IBOutlet private var stateLabel: UILabel!
    @IBOutlet private var usernameField: UITextField!
    @IBOutlet private var passwordField: UITextField!
    @IBOutlet private var loginButton: UIButton!
    @IBOutlet private var cancelButton: UIButton!
    @IBOutlet private var activityIndicator: UIActivityIndicatorView!

    @IBAction private func loginTapped() {
        guard let orgUrl = URL(string: "https://\(oktaDomain)"),
              let username = usernameField.text,
              let password = passwordField.text
        else { return }
        
        OktaAuthSdk.authenticate(with: orgUrl,
                                 username: username,
                                 password: password,
                                 onStatusChange: { authStatus in
            self.handleStatus(status: authStatus)
        },
                                 onError: { error in
            self.handleError(error)
        })

        activityIndicator.startAnimating()
    }
    
    @IBAction private func cancelTapped() {
        self.cancelTransaction()
    }

    @IBAction func forgotPasswordTapped(_ sender: Any) {
        guard let orgUrl = URL(string: "https://\(oktaDomain)"),
              let username = usernameField.text
        else { return }
        
        OktaAuthSdk.recoverPassword(with: orgUrl,
                                    username: username,
                                    factorType: .sms,
                                    onStatusChange: { authStatus in
            self.handleStatus(status: authStatus)
        }, onError: { error in
            self.handleError(error)
        })
        
        activityIndicator.startAnimating()
    }
    
    func handleStatus(status: OktaAuthStatus) {
        self.updateStatus(status: status)
        currentStatus = status

        switch status.statusType {
            
        case .success:
            let successState: OktaAuthStatusSuccess = status as! OktaAuthStatusSuccess
            handleSuccessStatus(sessionToken: successState.sessionToken!)

        case .passwordWarning:
            let warningPasswordStatus: OktaAuthStatusPasswordWarning = status as! OktaAuthStatusPasswordWarning
            warningPasswordStatus.skipPasswordChange(onStatusChange: { status in
                self.handleStatus(status: status)
            }) { error in
                self.handleError(error)
            }
            
        case .passwordExpired:
            let expiredPasswordStatus: OktaAuthStatusPasswordExpired = status as! OktaAuthStatusPasswordExpired
            self.handleChangePassword(passwordExpiredStatus: expiredPasswordStatus)
            
        case .MFAEnroll:
            let mfaEnroll: OktaAuthStatusFactorEnroll = status as! OktaAuthStatusFactorEnroll
            self.handleEnrollment(enrollmentStatus: mfaEnroll)
            
        case .MFAEnrollActivate:
            let mfaEnrollActivate: OktaAuthStatusFactorEnrollActivate = status as! OktaAuthStatusFactorEnrollActivate
            self.handleActivateEnrollment(status: mfaEnrollActivate)
            
        case .MFARequired:
            let mfaRequired: OktaAuthStatusFactorRequired = status as! OktaAuthStatusFactorRequired
            self.handleFactorRequired(factorRequiredStatus: mfaRequired)
            
        case .MFAChallenge:
            let mfaChallenge: OktaAuthStatusFactorChallenge = status as! OktaAuthStatusFactorChallenge
            let factor = mfaChallenge.factor
            switch factor.type {
            case .sms:
                let smsFactor = factor as! OktaFactorSms
                self.handleSmsChallenge(factor: smsFactor)
            case .TOTP:
                let totpFactor = factor as! OktaFactorTotp
                self.handleTotpChallenge(factor: totpFactor)
            case .question:
                let questionFactor = factor as! OktaFactorQuestion
                self.handleQuestionChallenge(factor: questionFactor)
            case .push:
                let pushFactor = factor as! OktaFactorPush
                self.handlePushChallenge(factor: pushFactor)
            default:
                    let alert = UIAlertController(title: "Error", message: "Recieved challenge for unsupported factor", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    present(alert, animated: true, completion: nil)
                    self.cancelTransaction()
            }
            
        case .recoveryChallenge:
            let mfaChallenge = status as! OktaAuthStatusRecoveryChallenge
            
            let alert = UIAlertController(title: "Enter code",
                                          message: "Please enter the verification code you received",
                                          preferredStyle: .alert)
            alert.addTextField { textField in
                textField.placeholder = "000 000"
            }
            alert.addAction(.init(title: "OK", style: .default, handler: { action in
                let code = alert.textFields?.first?.text ?? ""
                mfaChallenge.verifyFactor(passCode: code) { newStatus in
                    self.handleStatus(status: newStatus)
                } onError: { error in
                    self.handleError(error)
                }
            }))
            present(alert, animated: true)
            
        case .recovery:
            let mfaRecovery = status as! OktaAuthStatusRecovery
            if let question = mfaRecovery.recoveryQuestion {
                let alert = UIAlertController(title: "Security Question",
                                              message: question,
                                              preferredStyle: .alert)
                alert.addTextField { textField in
                    textField.placeholder = "Answer"
                }
                alert.addAction(.init(title: "OK", style: .default, handler: { action in
                    let answer = alert.textFields?.first?.text ?? ""
                    mfaRecovery.recoverWithAnswer(answer) { newStatus in
                        self.handleStatus(status: newStatus)
                    } onError: { error in
                        self.handleError(error)
                    }
                }))
                present(alert, animated: true)
            } else if let token = mfaRecovery.recoveryToken {
                mfaRecovery.recoverWithToken(token) { newStatus in
                    self.handleStatus(status: newStatus)
                } onError: { error in
                    self.handleError(error)
                }
            }
            
        case .passwordReset:
            let reset = status as! OktaAuthStatusPasswordReset
            let alert = UIAlertController(title: "Choose a new password",
                                          message: nil,
                                          preferredStyle: .alert)
            alert.addTextField { textField in
                textField.isSecureTextEntry = true
            }
            alert.addAction(.init(title: "OK", style: .default, handler: { action in
                let password = alert.textFields?.first?.text ?? ""
                reset.resetPassword(newPassword: password) { newStatus in
                    self.handleStatus(status: newStatus)
                } onError: { error in
                    self.handleError(error)
                }
            }))
            present(alert, animated: true)
            
        case .lockedOut,
             .unauthenticated:
              let alert = UIAlertController(title: "Error", message: "No handler for \(status.statusType.rawValue)", preferredStyle: .alert)
              alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
              present(alert, animated: true, completion: nil)
              self.cancelTransaction()
            
        case .unknown(_):
            let alert = UIAlertController(title: "Error", message: "Recieved unknown status", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            present(alert, animated: true, completion: nil)
            self.cancelTransaction()
        }
    }

    func updateStatus(status: OktaAuthStatus?, factorResult: OktaAPISuccessResponse.FactorResult? = nil) {
        guard let status = status else {
            stateLabel.text = "Unauthenticated"
            return
        }

        if let factorResult = factorResult {
            stateLabel.text = "\(status.statusType.rawValue) \(factorResult.rawValue)"
        } else {
            stateLabel.text = status.statusType.rawValue
        }
    }

    func handleSuccessStatus(sessionToken: String) {
        activityIndicator.stopAnimating()
 
        let flow: SessionTokenFlow
        do {
            flow = try SessionTokenFlow()
        } catch {
            //self.show(error)
            print(error)
            return
        }
        print(flow)
        Task {
            do {
                
                let token = try await flow.start(with: sessionToken)
                print("token \(token.idToken.debugDescription)")
                try Credential.store(token)
                let alert = UIAlertController(title: "Token Stored " + (token.idToken?.name!)!, message: "name: \((token.idToken?.name)!) Issuer: \((token.idToken?.issuer)!) Subject: \((token.idToken?.subject)!)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                present(alert, animated: true, completion: nil)
            } catch {
                print("The Error is: \(error)")
            }
        }

        self.loginButton.isEnabled = false
        self.cancelButton.isEnabled = false
    }

    func handleError(_ error: OktaError) {
        activityIndicator.stopAnimating()

        let alert = UIAlertController(title: "Error", message: error.description, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    func handleChangePassword(passwordExpiredStatus: OktaAuthStatusPasswordExpired) {
        let alert = UIAlertController(title: "Change Password", message: "Please choose new password", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Old Password" }
        alert.addTextField { $0.placeholder = "New Password" }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            guard let old = alert.textFields?[0].text,
                let new = alert.textFields?[1].text else { return }
            passwordExpiredStatus.changePassword(oldPassword: old,
                                                 newPassword: new,
                                                 onStatusChange: { status in
                                                    self.handleStatus(status: status)
            },
                                                 onError: { error in
                                                    self.handleError(error)
            })
        }))

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))

        present(alert, animated: true, completion: nil)
    }

    func handleFactorRequired(factorRequiredStatus: OktaAuthStatusFactorRequired) {
        updateStatus(status: factorRequiredStatus)
        
        let alert = UIAlertController(title: "Select verification factor", message: nil, preferredStyle: .actionSheet)
        factorRequiredStatus.availableFactors.forEach { factor in
            alert.addAction(UIAlertAction(title: factor.type.rawValue, style: .default, handler: { _ in
                factorRequiredStatus.selectFactor(factor,
                                                  onStatusChange: { status in
                    self.handleStatus(status: status)
                },
                                                  onError: { error in
                    self.handleError(error)
                })
            }))
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))
        present(alert, animated: true, completion: nil)
    }

    func handleEnrollment(enrollmentStatus: OktaAuthStatusFactorEnroll) {
        if enrollmentStatus.canSkipEnrollment() {
            enrollmentStatus.skipEnrollment(onStatusChange: { status in
                self.handleStatus(status: status)
            }) { error in
                self.handleError(error)
            }
            return
        }

        let alert = UIAlertController(title: "Select factor to enroll", message: nil, preferredStyle: .actionSheet)
        let factors = enrollmentStatus.availableFactors
        factors.forEach { factor in
            var title = factor.type.rawValue
            if let factorStatus = factor.status {
                title = title + " - " + "(\(factorStatus))"
            }
            alert.addAction(UIAlertAction(title: title, style: .default, handler: { _ in
                if factor.type == .sms {
                    let smsFactor = factor as! OktaFactorSms
                    let alert = UIAlertController(title: "MFA Enroll", message: "Please enter phone number", preferredStyle: .alert)
                    alert.addTextField { $0.placeholder = "Phone" }
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
                        guard let phone = alert.textFields?[0].text else { return }
                        smsFactor.enroll(phoneNumber: phone,
                                         onStatusChange: { status in
                                            self.handleStatus(status: status)
                        },
                                        onError: { error in
                                            self.handleError(error)
                        })
                    }))
                    self.present(alert, animated: true, completion: nil)
                } else if factor.type == .push {
                    let pushFactor = factor as! OktaFactorPush
                    pushFactor.enroll(questionId: nil, answer: nil, credentialId: nil, passCode: nil, phoneNumber: nil, onStatusChange: { status in
                        self.handleStatus(status: status)
                    }, onError: { error in
                        self.handleError(error)
                    })
                } else {
                    let alert = UIAlertController(title: "Error", message: "No handler for \(factor.type.rawValue) factor", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self.present(alert, animated: true, completion: nil)
                    self.cancelTransaction()
                }
            }))
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))
        present(alert, animated: true, completion: nil)
    }

    func handleActivateEnrollment(status: OktaAuthStatusFactorEnrollActivate) {
        let factor = status.factor
        guard factor.type == .sms ||
              factor.type == .push else {
            let alert = UIAlertController(title: "Error", message: "No handler for \(factor.type.rawValue) factor", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
            self.cancelTransaction()
            return
        }
        
        if factor.type == .sms {
            let smsFactor = factor as! OktaFactorSms
            
            let alert = UIAlertController(title: "MFA Activate", message: "Please enter code from SMS on \(smsFactor.phoneNumber ?? "?")", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Code" }
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
                guard let code = alert.textFields?[0].text else { return }
                status.activateFactor(passCode: code,
                                      onStatusChange: { status in
                                        self.handleStatus(status: status)
                },
                                      onError: { error in
                                        self.handleError(error)
                })
            }))
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
                self.cancelTransaction()
            }))
            present(alert, animated: true, completion: nil)
        }
        else {
            if status.factorResult == nil || status.factorResult == .waiting {
                status.activateFactor(passCode: nil, onStatusChange: { status in
                    self.handleStatus(status: status)
                }, onError: { error in
                    self.handleError(error)
                })
            }
        }
    }

    func handleTotpChallenge(factor: OktaFactorTotp) {
        let alert = UIAlertController(title: "MFA", message: "Please enter TOTP code", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Code" }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak factor] action in
            guard let code = alert.textFields?[0].text else { return }
            factor?.verify(passCode: code,
                           onStatusChange: { status in
                            self.handleStatus(status: status)
            },
                           onError: { error in
                            self.handleError(error)
            })
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func handleSmsChallenge(factor: OktaFactorSms) {
        let alert = UIAlertController(title: "MFA", message: "Please enter code from SMS on \(factor.phoneNumber ?? "?")", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Code" }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak factor] action in
            guard let code = alert.textFields?[0].text else { return }
            factor?.verify(passCode: code,
                           onStatusChange: { status in
                            self.handleStatus(status: status)
            },
                           onError: { error in
                            self.handleError(error)
            })
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func handleQuestionChallenge(factor: OktaFactorQuestion) {
        let alert = UIAlertController(title: "MFA", message: "Please answer security question: \(factor.factorQuestionText ?? "?")", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Answer" }
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { [weak factor] action in
            guard let answer = alert.textFields?[0].text else { return }
            factor?.verify(answerToSecurityQuestion: answer,
                           onStatusChange: { status in
                            self.handleStatus(status: status)
            },
                           onError: { error in
                            self.handleError(error)
            })
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            self.cancelTransaction()
        }))
        present(alert, animated: true, completion: nil)
    }

    func handlePushChallenge(factor: OktaFactorPush) {
        factor.verify(onStatusChange: { (status) in
            if status.factorResult == .waiting {
                self.updateStatus(status: status)
                DispatchQueue.main.asyncAfter(deadline:.now() + 5.0) {
                    self.handlePushChallenge(factor: factor)
                }
            } else {
                self.handleStatus(status: status)
            }
        }, onError: { (error) in
            self.handleError(error)
        })
    }

    func cancelTransaction() {
        guard let status = currentStatus else {
            return
        }
        
        if status.canCancel() {
            status.cancel(onSuccess: {
                self.activityIndicator.stopAnimating()
                self.loginButton.isEnabled = true
                self.currentStatus = nil
                self.updateStatus(status: nil)
            }, onError: { error in
                self.handleError(error)
            })
        }
    }
}
